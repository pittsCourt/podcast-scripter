// feeds.js
// Pulls RSS/Atom feeds on a schedule into news items for the editor sidebar.

const { XMLParser } = require('fast-xml-parser');
const db = require('./db');
const { normalizeUrl, clean } = require('./ingest');

const KEEP_DAYS = 14;
const FETCH_TIMEOUT_MS = 15000;

// Google News search feeds are reliable and need no API key. Add or remove
// feeds with the /api/feeds endpoints.
const DEFAULT_FEEDS = [
  {
    title: 'Google News: Real Salt Lake',
    category: 'team',
    url: 'https://news.google.com/rss/search?q=%22Real+Salt+Lake%22&hl=en-US&gl=US&ceid=US:en',
  },
  {
    title: 'Google News: MLS',
    category: 'league',
    url: 'https://news.google.com/rss/search?q=%22Major+League+Soccer%22+OR+MLS+soccer&hl=en-US&gl=US&ceid=US:en',
  },
];

const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_', textNodeName: '#text' });

function seedDefaultFeeds() {
  if (db.feedCount() === 0) DEFAULT_FEEDS.forEach(db.addFeed);
}

function text(value) {
  if (value == null) return '';
  if (typeof value === 'object') return String(value['#text'] ?? '');
  return String(value);
}

/** Normalizes RSS <item>s and Atom <entry>s into { title, link, published, summary, source }. */
function parseEntries(xml) {
  const doc = parser.parse(xml);
  const rssItems = doc?.rss?.channel?.item;
  const atomEntries = doc?.feed?.entry;
  const raw = [].concat(rssItems || atomEntries || []);

  return raw.map((entry) => {
    let link = entry.link;
    if (Array.isArray(link)) link = link.find((l) => !l['@_rel'] || l['@_rel'] === 'alternate') || link[0];
    if (link && typeof link === 'object') link = link['@_href'] || text(link);

    const source = text(entry.source) || null;
    let title = clean(text(entry.title));
    // Google News appends " - Source Name" to every headline.
    if (source && title.endsWith(` - ${source}`)) title = title.slice(0, -(source.length + 3));

    return {
      title,
      link: link ? String(link).trim() : null,
      published: text(entry.pubDate || entry.published || entry.updated) || null,
      summary: clean(text(entry.description || entry.summary || entry.content)).slice(0, 400),
      source,
    };
  });
}

async function refreshFeed(feed) {
  try {
    const res = await fetch(feed.url, {
      headers: { Accept: 'application/rss+xml, application/atom+xml, application/xml, text/xml' },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);

    let added = 0;
    for (const entry of parseEntries(await res.text())) {
      if (!entry.link || !entry.title) continue;
      const url = normalizeUrl(entry.link);
      if (db.newsExists(url, entry.title)) continue;
      const published = entry.published && !Number.isNaN(Date.parse(entry.published))
        ? new Date(Date.parse(entry.published)).toISOString()
        : null;
      // Google News descriptions just repeat the headline -- drop those.
      const summary = entry.summary.startsWith(entry.title) ? '' : entry.summary;
      db.insertItem({
        kind: 'news',
        title: entry.title,
        body: summary,
        url,
        source: entry.source || feed.title,
        category: feed.category,
        feedId: feed.id,
        publishedAt: published,
      });
      added += 1;
    }
    db.markFeedFetched(feed.id, null);
    return { feed: feed.title, added };
  } catch (err) {
    db.markFeedFetched(feed.id, err.message);
    return { feed: feed.title, error: err.message };
  }
}

async function refreshAll() {
  const results = [];
  for (const feed of db.listFeeds()) results.push(await refreshFeed(feed));
  db.pruneNews(KEEP_DAYS);
  return results;
}

function startScheduler(minutes) {
  if (!(minutes > 0)) return;
  const run = () => refreshAll().then((results) => {
    const summary = results.map((r) => (r.error ? `${r.feed}: ${r.error}` : `${r.feed}: +${r.added}`)).join(', ');
    console.log(`feeds refreshed -- ${summary || 'no feeds'}`);
  });
  setTimeout(run, 2000);
  setInterval(run, minutes * 60000).unref();
}

module.exports = { seedDefaultFeeds, refreshAll, startScheduler, parseEntries };
