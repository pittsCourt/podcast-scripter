// merge-db.js
// Combines two Newsdesk databases into a new file, e.g. when moving to a server that already
// has some data. Neither input is changed.
//
//   node scripts/merge-db.js <base.db> <other.db> <output.db>
//
// The output starts as a copy of <base> (all of it: projects, settings, inbox, news, power
// rankings). From <other> it adds what <base> doesn't have:
//   - projects, and their settings
//   - inbox items (X posts, articles, notes), skipping any with the same ID, or the same link
//     in the same project
//   - power-ranking snapshots for dates <base> doesn't have
// News isn't copied: each Newsdesk fetches its own and keeps two weeks.
//
// Both databases must be from Newsdesk with projects (started at least once on that version).
// Stop both Newsdesks first. Keep each notes.db next to its notes.db-wal and notes.db-shm (if
// present); they hold its most recent changes.

const fs = require('fs');
const { DatabaseSync } = require('node:sqlite');

const [basePath, otherPath, outPath] = process.argv.slice(2);
if (!basePath || !otherPath || !outPath) {
  console.error('usage: node scripts/merge-db.js <base.db> <other.db> <output.db>');
  process.exit(1);
}
for (const p of [basePath, otherPath]) {
  if (!fs.existsSync(p)) {
    console.error(`not found: ${p}`);
    process.exit(1);
  }
}
if (fs.existsSync(outPath)) {
  console.error(`${outPath} already exists; choose a new file name.`);
  process.exit(1);
}

const quote = (p) => `'${p.replace(/'/g, "''")}'`;

// Check both databases before writing anything.
const REQUIRED = { projects: ['id', 'name'], items: ['id', 'project_id', 'kind', 'url'], ranking_snapshots: ['project_id', 'source', 'date'], meta: ['key', 'value'] };
function check(path) {
  // Opened normally (not read-only) so recent changes in a notes.db-wal next to it are included.
  const probe = new DatabaseSync(path);
  try {
    for (const [table, needed] of Object.entries(REQUIRED)) {
      const have = probe.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
      const missing = needed.filter((c) => !have.includes(c));
      if (missing.length) throw new Error(`${path}: "${table}" is missing ${missing.join(', ')}. Start that Newsdesk once on the current version first.`);
    }
  } finally {
    probe.close();
  }
}
try {
  check(basePath);
  check(otherPath);
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

// A consistent copy of base, including anything still in its write-ahead log.
const base = new DatabaseSync(basePath);
base.exec(`VACUUM INTO ${quote(outPath)}`);
base.close();

const db = new DatabaseSync(outPath);
db.exec(`ATTACH DATABASE ${quote(otherPath)} AS other`);

const columns = (schema, table) => db.prepare(`PRAGMA ${schema}.table_info(${table})`).all().map((c) => c.name);
const shared = (table) => columns('main', table).filter((c) => columns('other', table).includes(c)).join(', ');
const count = (sql) => db.prepare(sql).get().n;

const before = {
  projects: count('SELECT COUNT(*) n FROM main.projects'),
  items: count("SELECT COUNT(*) n FROM main.items WHERE kind != 'news'"),
  rankings: count('SELECT COUNT(*) n FROM main.ranking_snapshots'),
};

db.exec('BEGIN');
try {
  db.exec(`INSERT OR IGNORE INTO main.projects (${shared('projects')}) SELECT ${shared('projects')} FROM other.projects`);
  // Settings for projects that only <other> has (base keeps its own for shared projects).
  db.exec(`INSERT OR IGNORE INTO main.meta (key, value)
           SELECT key, value FROM other.meta WHERE key LIKE 'config:%'`);

  const added = db.prepare(`
    SELECT o.project_id, o.kind, o.title, o.created_at FROM other.items o
    WHERE o.kind != 'news'
      AND o.id NOT IN (SELECT id FROM main.items)
      AND (o.url IS NULL OR NOT EXISTS (
        SELECT 1 FROM main.items i WHERE i.project_id = o.project_id AND i.url = o.url AND i.kind != 'news'))
    ORDER BY o.created_at`).all();
  db.exec(`
    INSERT INTO main.items (${shared('items')})
    SELECT ${shared('items')} FROM other.items o
    WHERE o.kind != 'news'
      AND o.id NOT IN (SELECT id FROM main.items)
      AND (o.url IS NULL OR NOT EXISTS (
        SELECT 1 FROM main.items i WHERE i.project_id = o.project_id AND i.url = o.url AND i.kind != 'news'))`);

  db.exec(`INSERT OR IGNORE INTO main.ranking_snapshots (${shared('ranking_snapshots')})
           SELECT ${shared('ranking_snapshots')} FROM other.ranking_snapshots`);
  db.exec('COMMIT');

  const after = {
    projects: count('SELECT COUNT(*) n FROM main.projects'),
    items: count("SELECT COUNT(*) n FROM main.items WHERE kind != 'news'"),
    rankings: count('SELECT COUNT(*) n FROM main.ranking_snapshots'),
  };
  console.log(`Merged into ${outPath}`);
  console.log(`  projects:          ${before.projects} -> ${after.projects}`);
  console.log(`  inbox items:       ${before.items} -> ${after.items}`);
  console.log(`  ranking snapshots: ${before.rankings} -> ${after.rankings}`);
  for (const item of added) console.log(`  + [${item.project_id}] ${item.kind}: ${item.title}`);
} catch (err) {
  db.exec('ROLLBACK');
  db.close();
  fs.rmSync(outPath, { force: true });
  console.error(`Merge failed, nothing written: ${err.message}`);
  process.exit(1);
}
db.close();
