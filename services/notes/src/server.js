// server.js
// Notes service for Podcast Scripter: an inbox for X posts, article links and
// notes (shared from a phone or the Mac app), plus RSS news for the editor.
//
//   GET    /api/health                      -> { ok, version } (no auth)
//   GET    /api/items?status=inbox|used|dismissed|all
//   POST   /api/items   { input, title? }   -> 201 new item, or 200 if the link was already saved
//   PATCH  /api/items/:id { status }
//   DELETE /api/items/:id
//   GET    /api/news?category=team|league&limit=20
//   GET    /api/feeds | POST /api/feeds { url, title, category } | DELETE /api/feeds/:id
//   POST   /api/feeds/refresh
//   GET    /api/standings?refresh=1          -> MLS conference tables + overall (ESPN, cached 30 min)
//   GET    /api/matches?refresh=1            -> the club's recent results and upcoming matches (ESPN)
//   GET    /api/rankings?season=2026         -> power rankings per source for a season (default: current)
//   POST   /api/rankings/sync                -> fetch all sources now (app open / Sync button)

const express = require('express');
const fs = require('fs');
const path = require('path');
const db = require('./db');
const feeds = require('./feeds');
const { buildItem, HttpError } = require('./ingest');
const { createAuth } = require('./auth');
const { getStandings, getMatches } = require('./espn');
const rankings = require('./rankings');
const { version } = require('../package.json');

const PORT = process.env.PORT || 3000;
const FEED_INTERVAL_MINUTES = Number(process.env.FEED_INTERVAL_MINUTES || 30);

const auth = createAuth({
  token: (process.env.NOTES_TOKEN || '').trim(),
  user: (process.env.NOTES_USER || '').trim(),
  password: process.env.NOTES_PASSWORD || '',
});

const app = express();
app.use(auth.middleware);
app.use(express.json({ limit: '256kb' }));
// iOS Shortcuts sometimes sends form bodies; accept both.
app.use(express.urlencoded({ extended: false }));
app.use(express.static(path.join(__dirname, '..', 'public')));

app.get('/api/health', (req, res) => {
  res.json({ ok: true, version, authRequired: auth.enabled });
});

const wrap = (fn) => (req, res) => Promise.resolve(fn(req, res)).catch((err) => {
  const status = err instanceof HttpError ? err.status : 500;
  if (status === 500) console.error(err);
  res.status(status).json({ error: status === 500 ? 'Something went wrong.' : err.message });
});

app.get('/api/items', wrap((req, res) => {
  const status = req.query.status || 'inbox';
  if (status !== 'all' && !db.STATUSES.includes(status)) throw new HttpError(400, 'Unknown status.');
  res.json(db.listInbox({ status }));
}));

app.post('/api/items', wrap(async (req, res) => {
  // `input` is the main field; `url` and `text` are accepted for convenience.
  const body = req.body || {};
  const input = body.input ?? body.url ?? body.text;
  const built = await buildItem(input, { title: body.title });

  if (built.url) {
    const existing = db.findInboxItemByUrl(built.url);
    if (existing) {
      // Re-sharing something already handled puts it back in the inbox.
      const item = existing.status === 'inbox' ? existing : db.updateStatus(existing.id, 'inbox');
      return res.status(200).json(item);
    }
  }
  res.status(201).json(db.insertItem(built));
}));

app.patch('/api/items/:id', wrap((req, res) => {
  const { status } = req.body || {};
  if (!db.STATUSES.includes(status)) throw new HttpError(400, `status must be one of ${db.STATUSES.join(', ')}.`);
  const item = db.updateStatus(req.params.id, status);
  if (!item) throw new HttpError(404, 'Item not found.');
  res.json(item);
}));

app.delete('/api/items/:id', wrap((req, res) => {
  if (!db.deleteItem(req.params.id)) throw new HttpError(404, 'Item not found.');
  res.status(204).end();
}));

app.get('/api/news', wrap((req, res) => {
  const { category } = req.query;
  const limit = Math.min(Number(req.query.limit) || 20, 100);
  res.json(db.listNews({ category, limit }));
}));

app.get('/api/feeds', wrap((req, res) => res.json(db.listFeeds())));

app.post('/api/feeds', wrap((req, res) => {
  const { url, title, category } = req.body || {};
  if (!/^https?:\/\//i.test(url || '')) throw new HttpError(400, 'url must be an http(s) feed URL.');
  if (!['team', 'league'].includes(category)) throw new HttpError(400, 'category must be team or league.');
  res.status(201).json(db.addFeed({ url, title: title || url, category }));
}));

app.delete('/api/feeds/:id', wrap((req, res) => {
  if (!db.deleteFeed(req.params.id)) throw new HttpError(404, 'Feed not found.');
  res.status(204).end();
}));

app.post('/api/feeds/refresh', wrap(async (req, res) => res.json(await feeds.refreshAll())));

// `refresh=1` skips the cache (the Mac app's Sync button).
const espnRoute = (load, what) => wrap(async (req, res) => {
  try {
    res.json(await load({ refresh: req.query.refresh === '1' }));
  } catch (err) {
    throw new HttpError(502, `Couldn't load ${what}: ${err.message}`);
  }
});

app.get('/api/standings', espnRoute(getStandings, 'standings'));
app.get('/api/matches', espnRoute(getMatches, 'matches'));

app.get('/api/rankings', wrap((req, res) => {
  const season = req.query.season ? Number(req.query.season) : undefined;
  if (season !== undefined && !Number.isInteger(season)) throw new HttpError(400, 'season must be a year, e.g. 2026.');
  res.json(rankings.summary(season));
}));
// Each source fails independently; its error comes back in the summary.
app.post('/api/rankings/sync', wrap(async (req, res) => res.json(await rankings.syncAll())));

/** One-time import of the old x-post-archiver history (data/posts.json). */
function importLegacyPosts() {
  const file = path.join(db.DATA_DIR, 'posts.json');
  if (!fs.existsSync(file)) return;
  let posts = [];
  try {
    posts = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    console.warn('posts.json is unreadable; skipping import');
    return;
  }
  let imported = 0;
  for (const post of posts) {
    const url = post.canonicalUrl || post.submittedUrl;
    if (url && db.findInboxItemByUrl(url)) continue;
    const author = [post.authorName, post.handle && `(${post.handle})`].filter(Boolean).join(' ');
    db.insertItem({
      id: post.id,
      kind: 'x_post',
      title: author || 'X post',
      body: post.text || '',
      url,
      source: 'X',
      authorName: post.authorName,
      handle: post.handle,
      mediaLinks: post.mediaLinks,
      postedOn: post.postedOn,
      createdAt: post.submittedAt,
    });
    imported += 1;
  }
  fs.renameSync(file, path.join(db.DATA_DIR, 'posts.imported.json'));
  console.log(`imported ${imported} posts from x-post-archiver`);
}

importLegacyPosts();
feeds.seedDefaultFeeds();
feeds.startScheduler(FEED_INTERVAL_MINUTES);

app.listen(PORT, () => {
  const modes = [auth.loginEnabled && 'login', auth.tokenEnabled && 'token'].filter(Boolean);
  console.log(`notes service v${version} listening on port ${PORT} (auth: ${modes.join(' + ') || 'none, API is open'})`);
});
