// ingest.js
// Turns whatever was shared (an X link, any other link, or plain text) into an
// inbox item. Link fetches never make a share fail: if a site blocks us, the
// link is still saved with whatever we could get.

const { parseTweetEmbed, decodeHtmlEntities, stripTags } = require('./parseTweet');

const X_STATUS_RE = /https?:\/\/(?:www\.|mobile\.)?(?:twitter\.com|x\.com)\/[A-Za-z0-9_]{1,15}\/status(?:es)?\/\d+/i;
const URL_ONLY_RE = /^https?:\/\/\S+$/i;
const FETCH_TIMEOUT_MS = 10000;
const USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/**
 * Decides what kind of item `input` is and builds it (without saving).
 * @param {string} input - a URL, or text that may contain an X post URL, or a note
 * @param {{ title?: string }} options - optional title for notes
 */
async function buildItem(input, { title } = {}) {
  const text = (input || '').trim();
  if (!text) throw new HttpError(400, 'Send a link or some text.');

  // The X share sheet sometimes sends "post text https://x.com/..." -- the link wins.
  const xMatch = text.match(X_STATUS_RE);
  if (xMatch) return fetchXPost(xMatch[0]);

  if (URL_ONLY_RE.test(text)) return fetchArticle(text);

  return buildNote(text, title);
}

function buildNote(text, title) {
  const lines = text.split('\n');
  const firstLine = lines[0].trim();
  if (title && title.trim()) {
    return { kind: 'note', title: title.trim(), body: text, source: 'Note' };
  }
  // Short single-line notes are all title; longer ones get a title from the first line.
  if (lines.length === 1 && firstLine.length <= 90) {
    return { kind: 'note', title: firstLine, body: '', source: 'Note' };
  }
  return {
    kind: 'note',
    title: firstLine.length > 90 ? `${firstLine.slice(0, 87)}…` : firstLine,
    body: text,
    source: 'Note',
  };
}

/** Strips tracking params and fragments so the same link de-duplicates. */
function normalizeUrl(raw) {
  try {
    const url = new URL(raw);
    url.hash = '';
    if (/(^|\.)(x|twitter)\.com$/i.test(url.hostname)) {
      url.search = '';
      url.hostname = 'x.com';
    } else {
      for (const key of [...url.searchParams.keys()]) {
        if (/^(utm_|fbclid$|gclid$|mc_|s$|ref$|ref_src$)/i.test(key)) url.searchParams.delete(key);
      }
    }
    return url.toString();
  } catch {
    return raw;
  }
}

async function fetchXPost(rawUrl) {
  const url = normalizeUrl(rawUrl);
  const oembedUrl = `https://publish.twitter.com/oembed?url=${encodeURIComponent(url)}&omit_script=true`;

  let res;
  try {
    res = await fetch(oembedUrl, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
  } catch {
    throw new HttpError(502, "Couldn't reach X. Try again in a moment.");
  }
  if (res.status === 404) {
    throw new HttpError(404, 'Post not found -- it may be deleted, private, or the URL is wrong.');
  }
  if (!res.ok) {
    throw new HttpError(502, `X returned HTTP ${res.status}. The account may be protected or embedding disabled.`);
  }

  const parsed = parseTweetEmbed(await res.json(), url);
  const author = [parsed.authorName, parsed.handle && `(${parsed.handle})`].filter(Boolean).join(' ');
  const publishedAt = parsed.postedOn && !Number.isNaN(Date.parse(parsed.postedOn))
    ? new Date(Date.parse(parsed.postedOn)).toISOString()
    : null;

  return {
    kind: 'x_post',
    title: author || 'X post',
    body: parsed.text,
    url: normalizeUrl(parsed.canonicalUrl || url),
    source: 'X',
    authorName: parsed.authorName,
    handle: parsed.handle,
    mediaLinks: parsed.mediaLinks,
    postedOn: parsed.postedOn,
    publishedAt,
  };
}

async function fetchArticle(rawUrl) {
  const url = normalizeUrl(rawUrl);
  const fallback = {
    kind: 'article',
    title: url,
    body: '',
    url,
    source: safeHostname(url),
  };

  let html;
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': USER_AGENT, Accept: 'text/html,application/xhtml+xml' },
      redirect: 'follow',
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    const type = res.headers.get('content-type') || '';
    if (!res.ok || !type.includes('html')) return fallback;
    // Metadata lives in <head>; no need to hold a whole page in memory.
    html = (await res.text()).slice(0, 500000);
  } catch {
    return fallback;
  }

  const meta = extractMeta(html);
  const publishedAt = meta.publishedTime && !Number.isNaN(Date.parse(meta.publishedTime))
    ? new Date(Date.parse(meta.publishedTime)).toISOString()
    : null;

  return {
    ...fallback,
    title: meta.title || fallback.title,
    body: meta.description || '',
    source: meta.siteName || fallback.source,
    imageUrl: meta.image ? absoluteUrl(meta.image, url) : null,
    publishedAt,
  };
}

/** Pulls Open Graph / standard meta tags out of an HTML page. */
function extractMeta(html) {
  const tags = {};
  for (const tag of html.match(/<meta\s[^>]*>/gi) || []) {
    const key = attr(tag, 'property') || attr(tag, 'name');
    const content = attr(tag, 'content');
    if (key && content && !(key.toLowerCase() in tags)) tags[key.toLowerCase()] = clean(content);
  }
  const titleTag = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  return {
    title: tags['og:title'] || tags['twitter:title'] || (titleTag && clean(titleTag[1])) || null,
    description: tags['og:description'] || tags['twitter:description'] || tags.description || null,
    image: tags['og:image'] || tags['twitter:image'] || null,
    siteName: tags['og:site_name'] || null,
    publishedTime: tags['article:published_time'] || tags['og:published_time'] || null,
  };
}

function attr(tag, name) {
  const m = tag.match(new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)')`, 'i'));
  return m ? (m[2] ?? m[3]) : null;
}

function clean(text) {
  return decodeHtmlEntities(stripTags(text)).replace(/\s+/g, ' ').trim();
}

function absoluteUrl(maybeRelative, base) {
  try {
    return new URL(maybeRelative, base).toString();
  } catch {
    return null;
  }
}

function safeHostname(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch {
    return null;
  }
}

module.exports = { buildItem, normalizeUrl, clean, HttpError };
