// config.js
// Show, script template, team/league and data-source settings, one set per project and shared
// by every device. Defaults come from config.default.json (edit it to adapt the app to another
// team); changes made in the Mac app's Settings are saved in the database on top of those
// defaults. Secrets (passwords, tokens, the Gemini key) stay in .env and are shared.

const fs = require('fs');
const path = require('path');
const db = require('./db');

const DEFAULTS_FILE = path.join(__dirname, '..', 'config.default.json');
const store = db.connection;
store.exec('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)');

const listeners = [];
const cache = new Map(); // project id -> merged settings
const projects = () => require('./projects');
const keyFor = (pid) => `config:${pid}`;

function defaults(pid = projects().current()) {
  const base = JSON.parse(fs.readFileSync(DEFAULTS_FILE, 'utf8'));
  // Older .env settings seed the original project only, so existing installs keep working.
  if (pid !== projects().defaultProjectId()) return base;
  const forwarded = (process.env.TFZ_FORWARDED_FROM || '').split(',').map((s) => s.trim()).filter(Boolean);
  if (forwarded.length) base.rankings.sources.tfz.forwardedFrom = forwarded;
  if (process.env.TFZ_SENDER) base.rankings.sources.tfz.sender = process.env.TFZ_SENDER;
  if (process.env.TEAM_ESPN_ID) base.team.espnTeamId = process.env.TEAM_ESPN_ID;
  if (process.env.RANKINGS_SYNC_SCHEDULE !== undefined) base.rankings.schedule = process.env.RANKINGS_SYNC_SCHEDULE;
  if (process.env.RANKINGS_SYNC_TZ) base.rankings.timeZone = process.env.RANKINGS_SYNC_TZ;
  return base;
}

/** Saved values win; anything missing (e.g. a setting added in a later version) falls back to defaults. */
function merge(base, saved) {
  if (Array.isArray(base) || Array.isArray(saved)) return saved !== undefined ? saved : base;
  if (base && typeof base === 'object' && saved && typeof saved === 'object') {
    const out = { ...base };
    for (const key of Object.keys(saved)) out[key] = merge(base[key], saved[key]);
    return out;
  }
  return saved !== undefined ? saved : base;
}

function load(pid) {
  const row = store.prepare('SELECT value FROM meta WHERE key = ?').get(keyFor(pid));
  let saved = {};
  try {
    saved = row ? JSON.parse(row.value) : {};
  } catch {
    console.warn(`saved settings for ${pid} are unreadable; using defaults`);
  }
  const merged = merge(defaults(pid), saved);
  cache.set(pid, merged);
  return merged;
}

/** Settings for a project (the current one by default). */
function get(pid = projects().current()) {
  return cache.get(pid) || load(pid);
}

const isText = (v) => typeof v === 'string';

/** Throws a readable error for anything the rest of the service can't work with. */
function validate(c) {
  const problems = [];
  if (!c.show || !isText(c.show.name) || !c.show.name.trim()) problems.push('show.name is required');
  if (!c.template || !Array.isArray(c.template.sections)) problems.push('template.sections must be a list');
  else c.template.sections.forEach((s, i) => {
    if (!isText(s.title) || !s.title.trim()) problems.push(`template.sections[${i}].title is required`);
    if (s.body !== undefined && !isText(s.body)) problems.push(`template.sections[${i}].body must be text`);
  });
  if (!c.team || !isText(c.team.name) || !c.team.name.trim()) problems.push('team.name is required');
  if (!c.team || !/^\d+$/.test(String(c.team.espnTeamId || ''))) problems.push('team.espnTeamId must be an ESPN team number');
  if (!c.team || !/^[a-z0-9.]+$/i.test(c.team.espnLeague || '')) problems.push('team.espnLeague must be an ESPN league code like usa.1');
  if (!Array.isArray(c.competitions)) problems.push('competitions must be a list');
  if (c.ai && !['gemini', 'ollama'].includes(c.ai.provider)) problems.push('ai.provider must be gemini or ollama');
  if (c.ai && c.ai.contextChars != null && !(Number(c.ai.contextChars) >= 10000)) problems.push('ai.contextChars must be at least 10000');
  if (problems.length) {
    const err = new Error(problems.join('; '));
    err.status = 400;
    throw err;
  }
}

function save(next, pid = projects().current()) {
  const merged = merge(defaults(pid), next);
  validate(merged);
  store.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value')
    .run(keyFor(pid), JSON.stringify(merged));
  cache.set(pid, merged);
  listeners.forEach((fn) => fn(merged, pid));
  return merged;
}

function reset(pid = projects().current()) {
  store.prepare('DELETE FROM meta WHERE key = ?').run(keyFor(pid));
  const fresh = load(pid);
  listeners.forEach((fn) => fn(fresh, pid));
  return fresh;
}

function forget(pid) {
  cache.delete(pid);
}

/** `fn(settings, projectId)` runs after a project's settings change. */
function onChange(fn) {
  listeners.push(fn);
}

module.exports = { get, save, reset, onChange, defaults, validate, forget };
