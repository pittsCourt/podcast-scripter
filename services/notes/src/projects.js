// projects.js
// A project is one show about one team, with its own settings, inbox, news feeds, power
// rankings and weekly sync. Every request runs "inside" a project (chosen with the
// X-Project header or ?project= on the URL, else the default project), and the rest of the
// service reads the current project from here instead of passing it around.

const { AsyncLocalStorage } = require('async_hooks');
const crypto = require('crypto');
const db = require('./db');

const store = db.connection;
const context = new AsyncLocalStorage();

store.exec(`
  CREATE TABLE IF NOT EXISTS projects (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
`);

const getMeta = (key) => (store.prepare('SELECT value FROM meta WHERE key = ?').get(key) || {}).value || null;
const setMeta = (key, value) => store.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value').run(key, value);

/** "Sounders Sound Off" -> "sounders-sound-off" (unique). */
function slug(name) {
  const base = String(name).toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'project';
  let id = base;
  for (let n = 2; store.prepare('SELECT 1 FROM projects WHERE id = ?').get(id); n += 1) id = `${base}-${n}`;
  return id;
}

function list() {
  const defaultId = defaultProjectId();
  return store.prepare('SELECT * FROM projects ORDER BY created_at').all()
    .map((p) => ({ id: p.id, name: p.name, createdAt: p.created_at, isDefault: p.id === defaultId }));
}

function get(id) {
  const row = store.prepare('SELECT * FROM projects WHERE id = ?').get(id);
  return row ? { id: row.id, name: row.name, createdAt: row.created_at } : null;
}

function create(name) {
  const id = slug(name);
  store.prepare('INSERT INTO projects (id, name, created_at) VALUES (?, ?, ?)').run(id, name.trim(), new Date().toISOString());
  return get(id);
}

function rename(id, name) {
  store.prepare('UPDATE projects SET name = ? WHERE id = ?').run(name.trim(), id);
  return get(id);
}

function remove(id) {
  store.prepare('DELETE FROM projects WHERE id = ?').run(id);
}

/** The project phone shares and unaddressed requests go to. */
function defaultProjectId() {
  const saved = getMeta('defaultProject');
  if (saved && get(saved)) return saved;
  const first = store.prepare('SELECT id FROM projects ORDER BY created_at LIMIT 1').get();
  return first ? first.id : null;
}

function setDefault(id) {
  setMeta('defaultProject', id);
}

/** The project the current request (or background job) is running for. */
function current() {
  const ctx = context.getStore();
  return (ctx && ctx.projectId) || defaultProjectId();
}

/** Runs `fn` inside project `id`; everything it calls sees that project. */
function run(id, fn) {
  return context.run({ projectId: id }, fn);
}

/**
 * First start with projects: everything that already exists becomes one project, named after
 * the show in the existing settings.
 */
function ensureDefault(showName) {
  if (defaultProjectId()) return defaultProjectId();
  const project = create(showName || 'My Show');
  setDefault(project.id);
  return project.id;
}

module.exports = { list, get, create, rename, remove, defaultProjectId, setDefault, current, run, ensureDefault, getMeta, setMeta, newId: () => crypto.randomUUID() };
