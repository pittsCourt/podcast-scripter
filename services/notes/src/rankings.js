// rankings.js
// RSL's power rankings from five sources, saved as dated snapshots so the app
// can graph the season. Synced on demand (app open / Sync button), never on a
// schedule. The first sync backfills whatever history each source exposes.
//
//   mls       MLSsoccer.com weekly articles (topic page -> article -> 30 ranking headers in order)
//   espn      ESPN biweekly articles (search API -> story -> "21. Real Salt Lake ... Previous ranking: 19")
//   tfz       TacticsFreeZone newsletter in Gmail over IMAP ("29. Real Salt Lake (-): ..."),
//             sent directly or forwarded from TFZ_FORWARDED_FROM
//   concacaf  Concacaf Club Ranking table (computed and published by Hypercube)
//   opta      Opta Power Rankings, read from the data bundled in the interactive table

const { decodeHtmlEntities, stripTags } = require('./parseTweet');
const db = require('./db');

const config = require('./config');
/** Settings are read on every sync, so changes apply without a restart. */
const teamName = () => config.get().team.name;
const sourceSettings = (id) => (config.get().rankings.sources || {})[id] || {};
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
const TIMEOUT_MS = 30000;

const store = db.connection;
store.exec(`
  CREATE TABLE IF NOT EXISTS ranking_snapshots (
    source        TEXT NOT NULL,
    date          TEXT NOT NULL,       -- YYYY-MM-DD the ranking was published
    rank          INTEGER NOT NULL,
    previous_rank INTEGER,             -- as the source reports it, when it does
    label         TEXT,                -- e.g. "Matchday 29"
    url           TEXT,                -- article / email id, also used to skip re-fetching
    extra         TEXT,                -- JSON: source-specific details
    fetched_at    TEXT NOT NULL,
    PRIMARY KEY (source, date)
  );
`);
// Added after the first release: the MLS season (calendar year) each ranking belongs to.
if (!store.prepare('PRAGMA table_info(ranking_snapshots)').all().some((c) => c.name === 'season')) {
  store.exec('ALTER TABLE ranking_snapshots ADD COLUMN season INTEGER');
}
store.exec(`
  UPDATE ranking_snapshots SET season = CAST(substr(date, 1, 4) AS INTEGER) WHERE season IS NULL;
  CREATE INDEX IF NOT EXISTS ranking_snapshots_season ON ranking_snapshots (season, source, date);
`);

const SOURCES = [
  { id: 'mls', name: 'MLS', group: 'League', scale: 30, fetch: fetchMLS },
  { id: 'espn', name: 'ESPN', group: 'League', scale: 30, fetch: fetchESPN },
  { id: 'tfz', name: 'TacticsFreeZone', group: 'League', scale: 30, fetch: fetchTFZ },
  { id: 'concacaf', name: 'Concacaf', group: 'Region', scale: null, fetch: fetchConcacaf },
  { id: 'opta', name: 'Opta', group: 'World', scale: null, fetch: fetchOpta },
];

const status = new Map(); // source id -> { checkedAt, error }

/** Sources switched on in Settings. */
const enabledSources = () => SOURCES.filter((source) => sourceSettings(source.id).enabled !== false);
const espnQuery = () => escape(sourceSettings('espn').query || 'MLS Power Rankings');
/** Escapes text for use inside a RegExp (team names like "St. Louis"). */
const escape = (text) => String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// --- helpers ---

async function get(url, { json = false, headers = {} } = {}) {
  const res = await fetch(url, {
    headers: { 'User-Agent': UA, ...headers },
    redirect: 'follow',
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} from ${new URL(url).hostname}`);
  return json ? res.json() : res.text();
}

const text = (html) => decodeHtmlEntities(stripTags(html)).replace(/\s+/g, ' ').trim();
const day = (date) => new Date(date).toISOString().slice(0, 10);
/** MLS seasons run within a calendar year, so the season is the year. */
const currentSeason = () => new Date().getFullYear();
const seasonOf = (date) => Number(date.slice(0, 4));
const seasonStart = () => `${currentSeason()}-01-01`;

function knownUrls(source) {
  return new Set(store.prepare('SELECT url FROM ranking_snapshots WHERE source = ? AND url IS NOT NULL').all(source).map((r) => r.url));
}

function save(source, snap) {
  store.prepare(`
    INSERT INTO ranking_snapshots (source, season, date, rank, previous_rank, label, url, extra, fetched_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (source, date) DO UPDATE SET
      season = excluded.season, rank = excluded.rank, previous_rank = excluded.previous_rank,
      label = excluded.label, url = excluded.url, extra = excluded.extra, fetched_at = excluded.fetched_at
  `).run(source, seasonOf(snap.date), snap.date, snap.rank, snap.previousRank ?? null, snap.label ?? null,
    snap.url ?? null, snap.extra ? JSON.stringify(snap.extra) : null, new Date().toISOString());
}

// --- MLS ---

async function fetchMLS() {
  const page = await get('https://www.mlssoccer.com/news/topics/power-rankings/');
  const links = [...new Set(page.match(/\/news\/power-rankings[a-z0-9-]*/g) || [])]
    .map((p) => `https://www.mlssoccer.com${p}`);
  const known = knownUrls('mls');
  const snaps = [];
  for (const url of links.filter((u) => !known.has(u))) {
    const html = await get(url);
    const published = (html.match(/"datePublished":"([^"]+)"/) || [])[1];
    if (!published || published < seasonStart()) continue;
    const teams = [...html.matchAll(/mls-c-ranking-header__title">\s*([^<]+?)\s*</g)].map((m) => text(m[1]));
    const index = teams.findIndex((t) => t === teamName());
    if (teams.length < 20 || index === -1) continue; // not a full 1-30 list
    const title = text((html.match(/<title>([\s\S]*?)<\/title>/) || [])[1] || '');
    snaps.push({ date: day(published), rank: index + 1, url, label: title.replace(/\s*\|.*$/, '') });
  }
  return snaps;
}

// --- ESPN ---

async function fetchESPN() {
  const query = encodeURIComponent(sourceSettings('espn').query || 'MLS Power Rankings');
  const search = await get(`https://site.web.api.espn.com/apis/search/v2?query=${query}&limit=50&type=article`, { json: true });
  const articles = (search.results || []).flatMap((r) => r.contents || [])
    .filter((a) => new RegExp(`^${espnQuery()}`, 'i').test(a.displayName || '') && (a.date || '') >= seasonStart());
  const known = knownUrls('espn');
  const snaps = [];
  for (const article of articles) {
    const url = (article.link && article.link.web) || `https://www.espn.com/soccer/story/_/id/${article.id}`;
    if (known.has(url)) continue;
    const story = await get(`https://content.core.api.espn.com/v1/sports/news/${article.id}`, { json: true });
    const body = text((story.headlines && story.headlines[0] && story.headlines[0].story) || '');
    const m = body.match(new RegExp(`\\b(\\d{1,2})\\.\\s*${escape(teamName())}\\b(?:.{0,200}?Previous ranking:\\s*(\\d{1,2}))?`));
    if (!m) continue;
    snaps.push({
      date: day(article.date),
      rank: Number(m[1]),
      previousRank: m[2] ? Number(m[2]) : null,
      url,
      label: article.displayName.replace(new RegExp(`^${espnQuery()}:\\s*`, 'i'), ''),
    });
  }
  return snaps;
}

// --- TacticsFreeZone (Gmail) ---

// Entries as written across the season (Gmail's text of a forward shows bold as *...*):
//   "29. Real Salt Lake (-):"   "27. *Real Salt Lake (-1)*"   "11. *Real Salt Lake* (+3):"
//   "14. *Real Salt Lake* (⬆️ 10):"   "8. *RSL* (-1):"   "25. *Real Salt Lake*:" (week 1, no change)
const teamAliases = () => [teamName(), ...(config.get().team.aliases || [])].filter(Boolean).map(escape);
const tfzEntry = () => new RegExp(
  `\\b(\\d{1,2})\\.\\s*[*_]*\\s*(?:${teamAliases().join('|')})\\b\\s*[*_]*\\s*(?:\\(([^)]*)\\))?\\s*[*_]*\\s*:`,
);

/** "+2" / "⬆️ 2" = up two, "-3" / "⬇️ 3" = down three, "-" = no change, none / "NR" = unknown. */
function parseChange(raw) {
  if (raw == null) return null;
  const t = raw.trim();
  if (/^[-–—]$/.test(t)) return 0;
  const n = Number((t.match(/\d+/) || [])[0]);
  if (!n) return null;
  if (/[+⬆↑▲]/.test(t)) return n;
  if (/[-–⬇↓▼]/.test(t)) return -n;
  return null;
}

async function fetchTFZ() {
  const user = process.env.GMAIL_USER;
  const pass = (process.env.GMAIL_APP_PASSWORD || '').replace(/\s+/g, '');
  if (!user || !pass) throw new Error('Gmail isn’t set up. Add GMAIL_USER and GMAIL_APP_PASSWORD to .env.');

  const { ImapFlow } = require('imapflow');
  const { simpleParser } = require('mailparser');
  const client = new ImapFlow({ host: 'imap.gmail.com', port: 993, secure: true, auth: { user, pass }, logger: false });
  const sender = sourceSettings('tfz').sender || 'tacticsfreezone@ghost.io';
  // Older issues forwarded in from another inbox count too (comma-separated addresses).
  const forwarders = (sourceSettings('tfz').forwardedFrom || []).map((s) => s.trim()).filter(Boolean);
  const fromQuery = [sender, ...forwarders].map((a) => `from:${a}`).join(' OR ');
  const known = knownUrls('tfz');
  const snaps = [];

  await client.connect();
  try {
    // "All Mail" so archived newsletters count too.
    const lock = await client.getMailboxLock('[Gmail]/All Mail');
    try {
      const after = seasonStart().replace(/-/g, '/');
      const uids = await client.search({ gmraw: `{${fromQuery}} subject:"Power Rankings" after:${after}` }, { uid: true });
      for (const uid of uids || []) {
        const message = await client.fetchOne(String(uid), { source: true, envelope: true }, { uid: true });
        const id = `gmail:${message.envelope.messageId}`;
        if (known.has(id)) continue;
        const parsed = await simpleParser(message.source);
        const body = (parsed.text || text(parsed.html || '')).replace(/\s+/g, ' ');
        // A forward's own sender must be TFZ, and its date is the original send date.
        const forwarded = body.match(/Forwarded message[\s-]*From:[^<]*<([^>]+)>\s*Date:\s*(.+?)\s+Subject:/i);
        if (forwarded && forwarded[1].toLowerCase() !== sender.toLowerCase()) continue;
        const sentOn = forwarded
          ? new Date(forwarded[2].replace(/^[A-Za-z]{3},\s*/, '').replace(/\s+at\s+/, ' '))
          : parsed.date || message.envelope.date;
        const m = body.match(tfzEntry());
        if (!m) continue;
        const rank = Number(m[1]);
        const change = parseChange(m[2]);
        if (Number.isNaN(sentOn.getTime())) continue;
        snaps.push({
          date: day(sentOn),
          rank,
          previousRank: change == null ? null : rank + change,
          url: id,
          label: ((parsed.subject || '').match(/Matchday\s*\d+/i) || [parsed.subject])[0],
        });
      }
    } finally {
      lock.release();
    }
  } finally {
    await client.logout().catch(() => {});
  }
  return snaps;
}

// --- Concacaf (Hypercube) ---

async function fetchConcacaf() {
  const html = await get('https://www.hypercube.nl/CCR/ranking.php?type=Club');
  const cells = html.split(/<\/t[dh]>/i).map((c) => text(c)).filter(Boolean);
  const at = cells.findIndex((c) => c === teamName());
  if (at === -1) throw new Error(`${teamName()} isn’t in the Concacaf ranking table.`);
  // Row: rank | club | country | league | points | change
  const before = cells.slice(Math.max(0, at - 3), at).reverse().find((c) => /^\d+$/.test(c));
  const after = cells.slice(at + 1, at + 6);
  const numbers = after.filter((c) => /^[+-]?[\d,]+$/.test(c));
  const rank = Number(before);
  const change = numbers.length > 1 ? Number(numbers[1].replace(/,/g, '')) : 0;
  return [{
    date: day(Date.now()),
    rank,
    previousRank: change ? rank + change : null,
    url: 'https://www.concacaf.com/rankings/club/',
    extra: { points: numbers[0] ? Number(numbers[0].replace(/,/g, '')) : null },
  }];
}

// --- Opta ---

async function fetchOpta() {
  const url = 'https://dataviz.theanalyst.com/opta-power-rankings/index.js';
  const res = await fetch(url, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(60000) });
  if (!res.ok) throw new Error(`HTTP ${res.status} from Opta`);
  const updated = res.headers.get('last-modified');
  const js = await res.text();
  const at = js.indexOf(`"contestantName":"${teamName()}"`);
  if (at === -1) throw new Error('Couldn’t find the team in Opta’s data (their page may have changed).');
  const record = js.slice(js.lastIndexOf('{', at), js.indexOf('}', at) + 1);
  const field = (name) => {
    const m = record.match(new RegExp(`"${name}":(-?[\\d.]+|null)`));
    return m && m[1] !== 'null' ? Number(m[1]) : null;
  };
  const rank = field('currentGlobalRank');
  if (!rank) throw new Error('Opta’s data didn’t include a global rank.');
  return [{
    date: day(updated || Date.now()),
    rank,
    previousRank: field('lastWeekGlobalRank'),
    url: 'https://theanalyst.com/articles/who-are-the-best-football-team-in-the-world-opta-power-rankings',
    extra: {
      rating: field('currentRating'),
      confederationRank: field('currentConfederationRank'),
      leagueRank: field('leagueGlobalRank'),
    },
  }];
}

// --- public API ---

/** Seasons that have saved rankings, newest first (always including the current one). */
function seasons() {
  const saved = store.prepare('SELECT DISTINCT season FROM ranking_snapshots ORDER BY season DESC').all().map((r) => r.season);
  return [...new Set([currentSeason(), ...saved])].sort((a, b) => b - a);
}

let inFlight = null;
let scheduleInfo = null;
const { getMeta, setMeta } = require('./schedule');

/** Fetches every source. Overlapping calls (Sync button + schedule) share one run. */
function syncAll() {
  if (!inFlight) {
    inFlight = runSync().finally(() => { inFlight = null; });
  }
  return inFlight;
}

async function runSync() {
  await Promise.all(enabledSources().map(async (source) => {
    try {
      const snaps = await source.fetch();
      snaps.forEach((s) => save(source.id, s));
      status.set(source.id, { checkedAt: new Date().toISOString(), error: null });
    } catch (err) {
      console.warn(`rankings: ${source.id} failed: ${err.message}`);
      status.set(source.id, { checkedAt: new Date().toISOString(), error: err.message });
    }
  }));
  setMeta('rankings.lastSyncAt', new Date().toISOString());
  return summary();
}

function setSchedule(info) {
  scheduleInfo = info;
}

function summary(season = currentSeason()) {
  const rows = store.prepare('SELECT * FROM ranking_snapshots WHERE season = ? ORDER BY date').all(season);
  const isCurrent = season === currentSeason();
  return {
    season,
    seasons: seasons(),
    lastSyncAt: getMeta('rankings.lastSyncAt'),
    syncing: !!inFlight,
    autoSync: scheduleInfo && scheduleInfo.description,
    sources: enabledSources().map((source) => {
      const history = rows.filter((r) => r.source === source.id).map((r) => ({
        date: r.date,
        rank: r.rank,
        label: r.label,
        url: r.url && r.url.startsWith('http') ? r.url : null,
      }));
      const mine = rows.filter((r) => r.source === source.id);
      const latest = mine[mine.length - 1];
      // Prefer the source's own "previous", else our previous snapshot.
      const previousRank = latest
        ? latest.previous_rank ?? (mine.length > 1 ? mine[mine.length - 2].rank : null)
        : null;
      // Sync status only describes the current season.
      const s = (isCurrent && status.get(source.id)) || {};
      return {
        id: source.id,
        name: source.name,
        group: source.group,
        scale: source.scale,
        latest: history[history.length - 1] || null,
        previousRank,
        extra: latest && latest.extra ? JSON.parse(latest.extra) : null,
        history,
        checkedAt: s.checkedAt || null,
        error: s.error || null,
      };
    }),
  };
}

module.exports = { syncAll, summary, setSchedule, tfzEntry, parseChange, SOURCES };
