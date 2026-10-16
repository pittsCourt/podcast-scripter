// migrate.js
// One-time move to projects: everything saved before projects existed becomes the default
// project. Safe to run on every start; each step checks whether it's already done.

const fs = require('fs');
const path = require('path');
const db = require('./db');
const projects = require('./projects');

const store = db.connection;
const hasColumn = (table, column) => store.prepare(`PRAGMA table_info(${table})`).all().some((c) => c.name === column);
const tableExists = (table) => !!store.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table);

function existingShowName() {
  const saved = projects.getMeta('config');
  try {
    if (saved) return JSON.parse(saved).show.fullName;
  } catch { /* fall through to the defaults file */ }
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'config.default.json'), 'utf8')).show.fullName;
  } catch {
    return 'My Show';
  }
}

function migrate() {
  const id = projects.ensureDefault(existingShowName());

  store.exec('BEGIN');
  try {
    // Inbox and news items
    if (!hasColumn('items', 'project_id')) store.exec('ALTER TABLE items ADD COLUMN project_id TEXT');
    store.prepare('UPDATE items SET project_id = ? WHERE project_id IS NULL').run(id);
    store.exec('CREATE INDEX IF NOT EXISTS items_project ON items (project_id, kind, status, created_at)');

    // Feeds: the old table had a unique URL, but two projects may follow the same feed.
    if (!hasColumn('feeds', 'project_id')) {
      store.exec(`
        CREATE TABLE feeds_new (
          id              TEXT PRIMARY KEY,
          project_id      TEXT NOT NULL,
          url             TEXT NOT NULL,
          title           TEXT NOT NULL,
          category        TEXT NOT NULL,
          last_fetched_at TEXT,
          last_error      TEXT,
          UNIQUE (project_id, url)
        );
      `);
      store.prepare(`INSERT INTO feeds_new (id, project_id, url, title, category, last_fetched_at, last_error)
                     SELECT id, ?, url, title, category, last_fetched_at, last_error FROM feeds`).run(id);
      store.exec('DROP TABLE feeds; ALTER TABLE feeds_new RENAME TO feeds;');
    }

    // Power rankings: the project becomes part of the key.
    if (tableExists('ranking_snapshots') && !hasColumn('ranking_snapshots', 'project_id')) {
      store.exec(`
        CREATE TABLE ranking_snapshots_new (
          project_id    TEXT NOT NULL,
          source        TEXT NOT NULL,
          season        INTEGER,
          date          TEXT NOT NULL,
          rank          INTEGER NOT NULL,
          previous_rank INTEGER,
          label         TEXT,
          url           TEXT,
          extra         TEXT,
          fetched_at    TEXT NOT NULL,
          PRIMARY KEY (project_id, source, date)
        );
      `);
      store.prepare(`INSERT INTO ranking_snapshots_new (project_id, source, season, date, rank, previous_rank, label, url, extra, fetched_at)
                     SELECT ?, source, season, date, rank, previous_rank, label, url, extra, fetched_at FROM ranking_snapshots`).run(id);
      store.exec(`
        DROP TABLE ranking_snapshots;
        ALTER TABLE ranking_snapshots_new RENAME TO ranking_snapshots;
        CREATE INDEX IF NOT EXISTS ranking_snapshots_season ON ranking_snapshots (project_id, season, source, date);
      `);
    }

    // Settings and sync bookkeeping become per-project keys.
    for (const key of ['config', 'rankings.lastSyncAt', 'rankings.lastScheduledSlot', 'rankings.scheduleSpec']) {
      const value = projects.getMeta(key);
      if (value !== null && projects.getMeta(`${key}:${id}`) === null) projects.setMeta(`${key}:${id}`, value);
      store.prepare('DELETE FROM meta WHERE key = ?').run(key);
    }
    store.exec('COMMIT');
  } catch (err) {
    store.exec('ROLLBACK');
    throw err;
  }
  return id;
}

module.exports = { migrate };
