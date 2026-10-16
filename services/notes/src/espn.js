// espn.js
// MLS standings and the club's matches from ESPN's public JSON (no key).
// Results are cached for CACHE_MINUTES; pass refresh to fetch fresh data
// (the Mac app's Sync button does). If ESPN is down, the last good copy is
// returned with stale: true.

const BASE = 'https://site.api.espn.com/apis';
const TEAM_ID = process.env.TEAM_ESPN_ID || '4771'; // Real Salt Lake
const TTL_MS = Number(process.env.STANDINGS_TTL_MINUTES || 30) * 60000;
const FETCH_TIMEOUT_MS = 15000;

const caches = new Map(); // key -> { data, fetchedAt }

async function espn(path) {
  const res = await fetch(`${BASE}${path}`, {
    headers: { Accept: 'application/json' },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`ESPN returned HTTP ${res.status}`);
  return res.json();
}

async function cached(key, refresh, load) {
  const hit = caches.get(key);
  if (hit && !refresh && Date.now() - hit.fetchedAt < TTL_MS) return { ...hit.data, stale: false };
  try {
    const data = { ...(await load()), updatedAt: new Date().toISOString() };
    caches.set(key, { data, fetchedAt: Date.now() });
    return { ...data, stale: false };
  } catch (err) {
    if (hit) return { ...hit.data, stale: true };
    throw err;
  }
}

function teamInfo(team = {}) {
  return {
    name: team.displayName,
    shortName: team.shortDisplayName || team.displayName,
    abbreviation: team.abbreviation,
    logo: (team.logos && team.logos[0] && team.logos[0].href) || team.logo || null,
  };
}

// --- standings ---

function stat(entry, name) {
  const found = entry.stats.find((s) => s.name === name);
  return found ? Number(found.value) : 0;
}

/** Playoff position from ESPN's per-team note. */
function qualification(entry) {
  const note = (entry.note && entry.note.description) || '';
  if (/round one/i.test(note)) return 'playoffs';
  if (/wild card/i.test(note)) return 'wild_card';
  return null;
}

function toRow(entry) {
  const team = teamInfo(entry.team);
  return {
    rank: stat(entry, 'rank'),
    team: team.name,
    shortName: team.shortName,
    abbreviation: team.abbreviation,
    logo: team.logo,
    played: stat(entry, 'gamesPlayed'),
    wins: stat(entry, 'wins'),
    draws: stat(entry, 'ties'),
    losses: stat(entry, 'losses'),
    goalsFor: stat(entry, 'pointsFor'),
    goalsAgainst: stat(entry, 'pointsAgainst'),
    goalDifference: stat(entry, 'pointDifferential'),
    points: stat(entry, 'points'),
    qualification: qualification(entry),
  };
}

/** MLS's Supporters' Shield order: points, wins, goal difference, goals for. */
function byTable(a, b) {
  return b.points - a.points || b.wins - a.wins || b.goalDifference - a.goalDifference
    || b.goalsFor - a.goalsFor || a.team.localeCompare(b.team);
}

function parseStandings(json) {
  const conferences = (json.children || []).map((child) => ({
    name: child.name.replace(/ Conference$/, ''),
    rows: child.standings.entries.map(toRow).sort((a, b) => a.rank - b.rank || byTable(a, b)),
  }));
  if (!conferences.length) throw new Error('No standings in the response.');

  const combined = conferences
    .flatMap((c) => c.rows)
    .sort(byTable)
    .map((row, index) => ({ ...row, rank: index + 1, qualification: null }));

  return {
    season: (json.seasons && json.seasons[0] && json.seasons[0].displayName) || '',
    conferences,
    combined,
  };
}

function getStandings({ refresh = false } = {}) {
  return cached('standings', refresh, async () => parseStandings(await espn('/v2/sports/soccer/usa.1/standings')));
}

// --- matches ---

function score(competitor) {
  const raw = competitor.score;
  const value = raw && typeof raw === 'object' ? raw.displayValue ?? raw.value : raw;
  const n = Number(value);
  return value == null || value === '' || Number.isNaN(n) ? null : n;
}

function toMatch(event) {
  const competition = event.competitions[0];
  const us = competition.competitors.find((c) => String(c.team.id) === TEAM_ID) || competition.competitors[0];
  const them = competition.competitors.find((c) => c !== us);
  const status = competition.status || event.status || {};
  const completed = !!(status.type && status.type.completed);
  const goalsFor = completed ? score(us) : null;
  const goalsAgainst = completed ? score(them) : null;

  let result = null;
  if (completed && goalsFor != null && goalsAgainst != null) {
    result = goalsFor > goalsAgainst ? 'W' : goalsFor < goalsAgainst ? 'L' : 'D';
  }

  return {
    id: String(event.id),
    date: event.date,
    competition: (event.seasonType && event.seasonType.name) || (event.league && event.league.name) || '',
    venue: (competition.venue && competition.venue.fullName) || null,
    broadcast: (competition.broadcasts || []).map((b) => b.media && b.media.shortName).filter(Boolean).join(', ') || null,
    isHome: us.homeAway === 'home',
    opponent: teamInfo(them && them.team),
    goalsFor,
    goalsAgainst,
    result,
    status: (status.type && status.type.shortDetail) || '',
    completed,
  };
}

function getMatches({ refresh = false } = {}) {
  return cached('matches', refresh, async () => {
    const [past, upcoming] = await Promise.all([
      espn(`/site/v2/sports/soccer/usa.1/teams/${TEAM_ID}/schedule`),
      espn(`/site/v2/sports/soccer/usa.1/teams/${TEAM_ID}/schedule?fixture=true`),
    ]);
    const results = (past.events || []).map(toMatch).filter((m) => m.completed)
      .sort((a, b) => b.date.localeCompare(a.date));
    const fixtures = (upcoming.events || []).map(toMatch).filter((m) => !m.completed)
      .sort((a, b) => a.date.localeCompare(b.date));
    return {
      team: teamInfo(past.team || upcoming.team),
      results: results.slice(0, 15),
      upcoming: fixtures.slice(0, 8),
    };
  });
}

module.exports = { getStandings, getMatches, parseStandings };
