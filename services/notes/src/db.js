// db.js
// SQLite storage via Node's built-in node:sqlite (no native deps to build).
//
// One `items` table holds both the story inbox (x_post / article / note) and
// news pulled from RSS feeds (kind = 'news'). Feeds live in `feeds`.

const { DatabaseSync } = require('node:sqlite');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, '..', 'data');
fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new DatabaseSync(path.join(DATA_DIR, 'notes.db'));

db.exec(`
  PRAGMA journal_mode = WAL;

  CREATE TABLE IF NOT EXISTS items (
    id           TEXT PRIMARY KEY,
    kind         TEXT NOT NULL,                  -- x_post | article | note | news
    status       TEXT NOT NULL DEFAULT 'inbox',  -- inbox | used | dismissed
    title        TEXT NOT NULL,
    body         TEXT NOT NULL DEFAULT '',
    url          TEXT,
    source       TEXT,
    author_name  TEXT,
    handle       TEXT,
    image_url    TEXT,
    media_links  TEXT NOT NULL DEFAULT '[]',     -- JSON array
    category     TEXT,                           -- news only: team | league
    feed_id      TEXT,
    posted_on    TEXT,                           -- as the source reports it (X gives a date only)
    published_at TEXT,                           -- ISO 8601 when known
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS items_kind_status ON items (kind, status, created_at);
  CREATE INDEX IF NOT EXISTS items_url ON items (url);

  CREATE TABLE IF NOT EXISTS feeds (
    id              TEXT PRIMARY KEY,
    url             TEXT NOT NULL UNIQUE,
    title           TEXT NOT NULL,
    category        TEXT NOT NULL,               -- team | league
    last_fetched_at TEXT,
    last_error      TEXT
  );
`);

const INBOX_KINDS = ['x_post', 'article', 'note'];
const STATUSES = ['inbox', 'used', 'dismissed'];

function toItem(row) {
  if (!row) return null;
  return {
    id: row.id,
    kind: row.kind,
    status: row.status,
    title: row.title,
    body: row.body,
    url: row.url,
    source: row.source,
    authorName: row.author_name,
    handle: row.handle,
    imageUrl: row.image_url,
    mediaLinks: JSON.parse(row.media_links || '[]'),
    category: row.category,
    postedOn: row.posted_on,
    publishedAt: row.published_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

// Every query is limited to the current project (see projects.js). Required lazily because
// projects.js itself uses this file's connection.
const pid = () => require('./projects').current();

function insertItem(item) {
  const now = new Date().toISOString();
  const row = {
    id: item.id || crypto.randomUUID(),
    createdAt: item.createdAt || now,
  };
  db.prepare(`
    INSERT INTO items (id, project_id, kind, status, title, body, url, source, author_name, handle, image_url,
                       media_links, category, feed_id, posted_on, published_at, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    row.id,
    pid(),
    item.kind,
    item.status || 'inbox',
    item.title,
    item.body || '',
    item.url || null,
    item.source || null,
    item.authorName || null,
    item.handle || null,
    item.imageUrl || null,
    JSON.stringify(item.mediaLinks || []),
    item.category || null,
    item.feedId || null,
    item.postedOn || null,
    item.publishedAt || null,
    row.createdAt,
    now,
  );
  return getItem(row.id);
}

function getItem(id) {
  return toItem(db.prepare('SELECT * FROM items WHERE id = ? AND project_id = ?').get(id, pid()));
}

/** Finds an existing inbox item (not news) with this URL, for de-duplication. */
function findInboxItemByUrl(url) {
  return toItem(db.prepare(`SELECT * FROM items WHERE url = ? AND kind != 'news' AND project_id = ?`).get(url, pid()));
}

/** True if this news story is already stored -- same link, or the same headline syndicated elsewhere. */
function newsExists(url, title) {
  return !!db.prepare(`SELECT 1 FROM items WHERE kind = 'news' AND project_id = ? AND (url = ? OR lower(title) = lower(?))`).get(pid(), url, title);
}

function listInbox({ status = 'inbox' } = {}) {
  const rows = status === 'all'
    ? db.prepare(`SELECT * FROM items WHERE kind != 'news' AND project_id = ? ORDER BY created_at DESC`).all(pid())
    : db.prepare(`SELECT * FROM items WHERE kind != 'news' AND project_id = ? AND status = ? ORDER BY created_at DESC`).all(pid(), status);
  return rows.map(toItem);
}

function listNews({ category, limit = 20 } = {}) {
  // Used (put in a script) and dismissed news stays stored, so feeds don't re-add it, but isn't listed.
  const order = 'ORDER BY COALESCE(published_at, created_at) DESC LIMIT ?';
  const rows = category
    ? db.prepare(`SELECT * FROM items WHERE kind = 'news' AND project_id = ? AND status = 'inbox' AND category = ? ${order}`).all(pid(), category, limit)
    : db.prepare(`SELECT * FROM items WHERE kind = 'news' AND project_id = ? AND status = 'inbox' ${order}`).all(pid(), limit);
  return rows.map(toItem);
}

function updateStatus(id, status) {
  const result = db.prepare('UPDATE items SET status = ?, updated_at = ? WHERE id = ? AND project_id = ?')
    .run(status, new Date().toISOString(), id, pid());
  return result.changes > 0 ? getItem(id) : null;
}

function deleteItem(id) {
  return db.prepare('DELETE FROM items WHERE id = ? AND project_id = ?').run(id, pid()).changes > 0;
}

/** Drops news older than `days` so the table doesn't grow forever. */
function pruneNews(days) {
  const cutoff = new Date(Date.now() - days * 86400000).toISOString();
  db.prepare(`DELETE FROM items WHERE kind = 'news' AND project_id = ? AND COALESCE(published_at, created_at) < ?`).run(pid(), cutoff);
}

// --- feeds ---

function toFeed(row) {
  return row && {
    id: row.id,
    url: row.url,
    title: row.title,
    category: row.category,
    lastFetchedAt: row.last_fetched_at,
    lastError: row.last_error,
  };
}

function listFeeds() {
  return db.prepare('SELECT * FROM feeds WHERE project_id = ? ORDER BY category, title').all(pid()).map(toFeed);
}

function addFeed({ url, title, category }) {
  const id = crypto.randomUUID();
  db.prepare('INSERT INTO feeds (id, project_id, url, title, category) VALUES (?, ?, ?, ?, ?)').run(id, pid(), url, title, category);
  return toFeed(db.prepare('SELECT * FROM feeds WHERE id = ?').get(id));
}

function deleteFeed(id) {
  return db.prepare('DELETE FROM feeds WHERE id = ? AND project_id = ?').run(id, pid()).changes > 0;
}

function markFeedFetched(id, error) {
  db.prepare('UPDATE feeds SET last_fetched_at = ?, last_error = ? WHERE id = ?')
    .run(new Date().toISOString(), error || null, id);
}

function feedCount() {
  return db.prepare('SELECT COUNT(*) AS n FROM feeds WHERE project_id = ?').get(pid()).n;
}

function itemCount() {
  return db.prepare('SELECT COUNT(*) AS n FROM items WHERE project_id = ?').get(pid()).n;
}

/** Everything stored for a project (used when a project is deleted). */
function deleteProjectData(projectId) {
  db.prepare('DELETE FROM items WHERE project_id = ?').run(projectId);
  db.prepare('DELETE FROM feeds WHERE project_id = ?').run(projectId);
  db.prepare('DELETE FROM ranking_snapshots WHERE project_id = ?').run(projectId);
  db.prepare("DELETE FROM meta WHERE key LIKE ?").run(`%:${projectId}`);
}

module.exports = {
  connection: db,
  deleteProjectData,
  DATA_DIR,
  INBOX_KINDS,
  STATUSES,
  insertItem,
  getItem,
  findInboxItemByUrl,
  newsExists,
  listInbox,
  listNews,
  updateStatus,
  deleteItem,
  pruneNews,
  listFeeds,
  addFeed,
  deleteFeed,
  markFeedFetched,
  feedCount,
  itemCount,
};
