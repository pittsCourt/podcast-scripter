// parseTweet.js
// Turns an X/Twitter oEmbed API response into a clean, plain-object record.
// The oEmbed response gives us `author_name`, `author_url`, and an `html`
// blockquote snippet -- this module strips that snippet down to plain text,
// pulls out the handle, any attached media links, and the posted-on date.

const HTML_ENTITIES = {
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&apos;': "'",
  '&mdash;': '\u2014',
  '&ndash;': '\u2013',
  '&nbsp;': ' ',
  '&hellip;': '\u2026',
};

function decodeHtmlEntities(str) {
  return str
    .replace(/&(amp|lt|gt|quot|#39|apos|mdash|ndash|nbsp|hellip);/g, (m) => HTML_ENTITIES[m] || m)
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
}

function stripTags(html) {
  return html.replace(/<[^>]+>/g, '');
}

/**
 * @param {object} oembed - parsed JSON from publish.twitter.com/oembed (or publish.x.com/oembed)
 * @param {string} submittedUrl - the raw URL the user pasted in
 * @returns {object} clean record ready to store
 */
function parseTweetEmbed(oembed, submittedUrl) {
  const html = oembed.html || '';

  // The tweet body lives inside the first <p>...</p> in the blockquote.
  const pMatch = html.match(/<p[^>]*>([\s\S]*?)<\/p>/);
  let bodyHtml = pMatch ? pMatch[1] : '';

  // Pull out any attached-media links (pic.twitter.com / video previews)
  // before stripping tags, then drop them from the body text -- they're
  // just "photo attached" links, not meaningful words.
  // Twitter's oEmbed HTML puts a t.co redirect in the href but labels the
  // link text as "pic.twitter.com/..." (or "video.twimg.com/...") -- so we
  // match on the visible text, and store the href (the actual resolvable
  // link) as the media link.
  const mediaLinks = [];
  const mediaRegex = /<a[^>]*href="([^"]*)"[^>]*>([^<]*(?:pic\.twitter\.com|pic\.x\.com|video\.twimg\.com)[^<]*)<\/a>/g;
  let match;
  while ((match = mediaRegex.exec(bodyHtml)) !== null) {
    mediaLinks.push(decodeHtmlEntities(match[1]));
  }
  bodyHtml = bodyHtml.replace(mediaRegex, '');

  // Any other <a>...</a> (mentions, hashtags, t.co links) -- keep the
  // visible text, drop the wrapper.
  bodyHtml = bodyHtml.replace(/<a[^>]*>([\s\S]*?)<\/a>/g, '$1');

  const text = decodeHtmlEntities(stripTags(bodyHtml)).trim();

  // The posted-on date shows up as the last <a>...</a> in the snippet,
  // right after the "&mdash; Author Name (@handle)" bit, e.g.
  // <a href="https://twitter.com/handle/status/123">August 3, 2016</a>.
  // Note: X's oEmbed response only ever includes a date here, not a
  // time-of-day.
  const afterBody = html.split(/<\/p>/).pop() || '';
  const trailingLinks = afterBody.match(/<a[^>]*>([\s\S]*?)<\/a>/g) || [];
  let postedOn = null;
  if (trailingLinks.length) {
    const last = trailingLinks[trailingLinks.length - 1];
    postedOn = decodeHtmlEntities(stripTags(last)).trim() || null;
  }

  const handleRaw = (oembed.author_url || '').split('/').filter(Boolean).pop();
  const handle = handleRaw ? `@${handleRaw}` : null;

  return {
    submittedUrl,
    canonicalUrl: oembed.url || submittedUrl,
    authorName: oembed.author_name || null,
    handle,
    text,
    mediaLinks,
    postedOn,
  };
}

module.exports = { parseTweetEmbed, decodeHtmlEntities, stripTags };
