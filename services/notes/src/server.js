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
//   GET    /api/projects | POST /api/projects | PATCH /api/projects/:id | DELETE /api/projects/:id
//          (all other /api routes act on the project in X-Project or ?project=, else the default)
//   GET    /api/config | PUT /api/config | POST /api/config/reset | GET /api/config/defaults
//   GET    /api/espn/teams?league=usa.1      -> teams for the Settings team picker
//   GET    /api/ai/status | POST /api/ai/test   -> which Gemma provider is active, and a quick check
//   POST   /api/ai/ask | suggest-story | briefing | intro-bullets -> the Gemma features
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
const { getStandings, getMatches, listTeams } = require('./espn');
const rankings = require('./rankings');
const projects = require('./projects');
const { migrate } = require('./migrate');
const schedule = require('./schedule');
const config = require('./config');
const ai = require('./ai');
const assistant = require('./assistant');
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
// Ask Gemma sends the app's scripts along with the question.
app.use(express.json({ limit: '8mb' }));
// iOS Shortcuts sometimes sends form bodies; accept both.
app.use(express.urlencoded({ extended: false }));
app.use(express.static(path.join(__dirname, '..', 'public')));

// Every API request runs inside a project: X-Project header, ?project=, else the default.
// (The iPhone Shortcut and inbox page can pick one with ?project=<id>.)
app.use('/api', (req, res, next) => {
  const requested = req.get('x-project') || req.query.project;
  const id = requested || projects.defaultProjectId();
  if (requested && !projects.get(requested)) {
    return res.status(404).json({ error: `No project "${requested}".` });
  }
  projects.run(id, next);
});

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

// --- projects (one show and team each) ---
const projectInfo = (p) => {
  const cfg = config.get(p.id);
  return {
    ...p,
    isDefault: p.id === projects.defaultProjectId(),
    showName: cfg.show.fullName,
    team: { name: cfg.team.name, shortName: cfg.team.shortName, espnSport: cfg.team.espnSport, espnLeague: cfg.team.espnLeague },
  };
};

app.get('/api/projects', wrap((req, res) => res.json(projects.list().map(projectInfo))));

/**
 * { name, fromProject?, team?, show? }: starts from another project's settings (or the
 * defaults), with the new team and show details on top.
 */
app.post('/api/projects', wrap((req, res) => {
  const { name, fromProject, team, show } = req.body || {};
  if (!name || !String(name).trim()) throw new HttpError(400, 'A project needs a name.');
  const base = fromProject && projects.get(fromProject) ? config.get(fromProject) : config.defaults('__new__');
  const settings = JSON.parse(JSON.stringify(base));
  if (team) {
    settings.team = { ...settings.team, ...team, aliases: team.aliases || [team.shortName].filter(Boolean) };
    settings.news = { ...settings.news, teamQuery: `"${settings.team.name}"` };
  }
  settings.show = { ...settings.show, ...(show || {}), fullName: (show && show.fullName) || String(name).trim() };
  try {
    config.validate(settings);
  } catch (err) {
    throw new HttpError(400, err.message);
  }
  const project = projects.create(String(name));
  projects.run(project.id, () => {
    config.save(settings, project.id);
    feeds.syncDefaultFeeds(settings);
    feeds.refreshAll().catch(() => {});
  });
  res.status(201).json(projectInfo(project));
}));

app.patch('/api/projects/:id', wrap((req, res) => {
  const project = projects.get(req.params.id);
  if (!project) throw new HttpError(404, 'Project not found.');
  const { name, makeDefault } = req.body || {};
  if (name && String(name).trim()) projects.rename(project.id, String(name));
  if (makeDefault) projects.setDefault(project.id);
  res.json(projectInfo(projects.get(project.id)));
}));

app.delete('/api/projects/:id', wrap((req, res) => {
  const project = projects.get(req.params.id);
  if (!project) throw new HttpError(404, 'Project not found.');
  if (projects.list().length === 1) throw new HttpError(400, 'You can’t delete the only project.');
  schedule.stopWeekly(project.id);
  db.deleteProjectData(project.id);
  config.forget(project.id);
  projects.remove(project.id);
  res.status(204).end();
}));

// --- settings (show, template, team, sources) ---
app.get('/api/config', wrap((req, res) => res.json(config.get())));
app.put('/api/config', wrap((req, res) => {
  try {
    res.json(config.save(req.body || {}));
  } catch (err) {
    throw new HttpError(err.status || 500, err.message);
  }
}));
app.post('/api/config/reset', wrap((req, res) => res.json(config.reset())));
app.get('/api/config/defaults', wrap((req, res) => res.json(config.defaults())));
app.get('/api/espn/teams', wrap(async (req, res) => {
  const league = req.query.league || config.get().team.espnLeague;
  if (!/^[a-z0-9.]+$/i.test(league)) throw new HttpError(400, 'league must be an ESPN league code like usa.1');
  try {
    res.json(await listTeams(league));
  } catch (err) {
    throw new HttpError(502, `Couldn't load teams for ${league}: ${err.message}`);
  }
}));

// --- Gemma ---
app.get('/api/ai/status', wrap((req, res) => res.json(ai.status())));
// Each feature: the app sends its data (scripts, tracker); the service adds its own and asks Gemma.
const aiRoute = (fn) => wrap(async (req, res) => {
  try {
    res.json(await fn(req.body || {}));
  } catch (err) {
    throw new HttpError(err.status || 502, err.message);
  }
});
app.post('/api/ai/ask', aiRoute(assistant.ask));
app.post('/api/ai/suggest-story', aiRoute(assistant.suggestStory));
app.post('/api/ai/briefing', aiRoute(assistant.briefing));
app.post('/api/ai/intro-bullets', aiRoute(assistant.introBullets));
app.post('/api/ai/test', wrap(async (req, res) => {
  try {
    const reply = await ai.generate({ prompt: 'Reply with exactly: Ready to help with the show.', temperature: 0 });
    res.json({ ok: true, ...reply });
  } catch (err) {
    throw new HttpError(502, err.message);
  }
}));

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

migrate();
projects.run(projects.defaultProjectId(), importLegacyPosts);

const startRankingsSchedule = (cfg, id) => rankings.setSchedule(
  schedule.startWeekly(id, cfg.rankings.schedule, cfg.rankings.timeZone || 'UTC', rankings.syncAll),
  id,
);
for (const project of projects.list()) {
  projects.run(project.id, () => {
    feeds.seedDefaultFeeds();
    startRankingsSchedule(config.get(), project.id);
  });
}
feeds.startScheduler(FEED_INTERVAL_MINUTES);
config.onChange((cfg, id) => projects.run(id, () => {
  startRankingsSchedule(cfg, id);
  feeds.syncDefaultFeeds(cfg);
}));

app.listen(PORT, () => {
  const modes = [auth.loginEnabled && 'login', auth.tokenEnabled && 'token'].filter(Boolean);
  console.log(`notes service v${version} listening on port ${PORT} (auth: ${modes.join(' + ') || 'none, API is open'})`);
});
