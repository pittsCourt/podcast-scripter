// config.js
// Show, script template, team/league and data-source settings, shared by every
// device. Defaults come from config.default.json (edit it to adapt the app to
// another team); changes made in the Mac app's Settings are saved in the
// database on top of those defaults. Secrets (passwords, tokens) stay in .env.

const fs = require('fs');
const path = require('path');
const db = require('./db');

const DEFAULTS_FILE = path.join(__dirname, '..', 'config.default.json');
const store = db.connection;
store.exec('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)');

const listeners = [];
let current = null;

function defaults() {
  const base = JSON.parse(fs.readFileSync(DEFAULTS_FILE, 'utf8'));
  // Seed from older .env settings so existing installs keep working.
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

function load() {
  const row = store.prepare("SELECT value FROM meta WHERE key = 'config'").get();
  let saved = {};
  try {
    saved = row ? JSON.parse(row.value) : {};
  } catch {
    console.warn('saved config is unreadable; using defaults');
  }
  current = merge(defaults(), saved);
  return current;
}

function get() {
  return current || load();
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

function save(next) {
  const merged = merge(defaults(), next);
  validate(merged);
  store.prepare("INSERT INTO meta (key, value) VALUES ('config', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value")
    .run(JSON.stringify(merged));
  current = merged;
  listeners.forEach((fn) => fn(current));
  return current;
}

function reset() {
  store.prepare("DELETE FROM meta WHERE key = 'config'").run();
  load();
  listeners.forEach((fn) => fn(current));
  return current;
}

function onChange(fn) {
  listeners.push(fn);
}

module.exports = { get, save, reset, onChange, defaults };
