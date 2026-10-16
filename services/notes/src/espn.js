// espn.js
// MLS standings and the club's matches from ESPN's public JSON (no key).
// Results are cached for CACHE_MINUTES; pass refresh to fetch fresh data
// (the Mac app's Sync button does). If ESPN is down, the last good copy is
// returned with stale: true.

const config = require('./config');

const BASE = 'https://site.api.espn.com/apis';
const TTL_MS = Number(process.env.STANDINGS_TTL_MINUTES || 30) * 60000;
const FETCH_TIMEOUT_MS = 15000;

const caches = new Map(); // key -> { data, fetchedAt }
// A different team or league makes cached results meaningless.
config.onChange(() => caches.clear());

const team = () => config.get().team;
const teamId = () => String(team().espnTeamId);
const sport = () => team().espnSport || 'soccer';

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
  return cached('standings', refresh, async () => parseStandings(await espn(`/v2/sports/${sport()}/${team().espnLeague}/standings`)));
}

// --- matches ---

function score(competitor) {
  const raw = competitor.score;
  const value = raw && typeof raw === 'object' ? raw.displayValue ?? raw.value : raw;
  const n = Number(value);
  return value == null || value === '' || Number.isNaN(n) ? null : n;
}

/** Competitions the club can play in (Settings). ESPN files each under its own league code. */
function competitions() {
  const list = (config.get().competitions || []).filter((c) => c.enabled !== false && c.espnLeague);
  const league = team().espnLeague;
  // The team's own league is always included.
  if (!list.some((c) => c.espnLeague === league)) list.unshift({ name: league.toUpperCase(), espnLeague: league });
  return list.map((c) => ({ slug: c.espnLeague, name: c.name }));
}

function toMatch(event, competitionName) {
  const competition = event.competitions[0];
  const us = competition.competitors.find((c) => String(c.team.id) === teamId()) || competition.competitors[0];
  const them = competition.competitors.find((c) => c !== us);
  const status = competition.status || event.status || {};
  const completed = !!(status.type && status.type.completed);
  const goalsFor = completed ? score(us) : null;
  const goalsAgainst = completed ? score(them) : null;
  const detail = (status.type && status.type.shortDetail) || '';

  let result = null;
  if (completed && goalsFor != null && goalsAgainst != null) {
    result = goalsFor > goalsAgainst ? 'W' : goalsFor < goalsAgainst ? 'L' : 'D';
  }
  // Level after extra time and decided on penalties: the result stays a draw, plus who won the shootout.
  let shootout = null;
  if (result === 'D' && /pen/i.test(detail)) {
    if (us.winner) shootout = 'W';
    else if (them && them.winner) shootout = 'L';
  }

  const stage = (event.seasonType && event.seasonType.name) || null;
  // e.g. "Tigres UANL win 6-5 on penalties"
  const note = ((competition.notes || [])[0] && competition.notes[0].headline) || null;

  return {
    id: String(event.id),
    date: event.date,
    competition: competitionName,
    stage,
    note,
    venue: (competition.venue && competition.venue.fullName) || null,
    broadcast: (competition.broadcasts || []).map((b) => b.media && (b.media.shortName || b.media.name) || (b.names || [])[0])
      .filter(Boolean).join(', ') || null,
    isHome: us.homeAway === 'home',
    opponent: teamInfo(them && them.team),
    goalsFor,
    goalsAgainst,
    result,
    shootout,
    status: detail,
    completed,
  };
}

const involvesTeam = (event) => (event.competitions[0].competitors || []).some((c) => String(c.team.id) === teamId());

/**
 * All of the club's matches in one competition this season. Cup schedules aren't always
 * attached to the team on ESPN, so the full-season scoreboard is checked as well.
 */
async function competitionMatches({ slug, name }, season) {
  const isHomeLeague = slug === team().espnLeague;
  const sources = [
    espn(`/site/v2/sports/${sport()}/${slug}/teams/${teamId()}/schedule?season=${season}`),
    espn(`/site/v2/sports/${sport()}/${slug}/teams/${teamId()}/schedule?season=${season}&fixture=true`),
  ];
  if (!isHomeLeague) sources.push(espn(`/site/v2/sports/${sport()}/${slug}/scoreboard?dates=${season}&limit=1000`));

  const responses = await Promise.allSettled(sources);
  const events = new Map();
  let club = null;
  for (const response of responses) {
    if (response.status !== 'fulfilled') continue;
    club = club || response.value.team || null;
    for (const event of response.value.events || []) {
      // Team schedules come first and carry the stage (seasonType); the scoreboard only fills gaps.
      const id = String(event.id);
      if (involvesTeam(event) && !events.has(id)) events.set(id, event);
    }
  }
  if (isHomeLeague && responses.every((r) => r.status === 'rejected')) {
    throw responses[0].reason; // the team's league is required; cups are best-effort
  }
  return { club, matches: [...events.values()].map((e) => toMatch(e, name)) };
}

function getMatches({ refresh = false } = {}) {
  return cached('matches', refresh, async () => {
    const season = new Date().getFullYear();
    const list = competitions();
    const perCompetition = await Promise.all(list.map((c) => competitionMatches(c, season)));
    const all = perCompetition.flatMap((c) => c.matches);
    const club = perCompetition.map((c) => c.club).find(Boolean);
    return {
      season,
      team: teamInfo(club),
      // Competitions the club has matches in this season, in the order above.
      competitions: list.map((c) => c.name).filter((n) => all.some((m) => m.competition === n)),
      results: all.filter((m) => m.completed).sort((a, b) => b.date.localeCompare(a.date)),
      upcoming: all.filter((m) => !m.completed).sort((a, b) => a.date.localeCompare(b.date)),
    };
  });
}

/** Teams in a league, for the Settings team picker. */
async function listTeams(league = team().espnLeague) {
  const json = await espn(`/site/v2/sports/${sport()}/${league}/teams`);
  const teams = ((json.sports || [])[0]?.leagues || [])[0]?.teams || [];
  return teams.map(({ team: t }) => ({ id: String(t.id), ...teamInfo(t) }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

module.exports = { getStandings, getMatches, listTeams, parseStandings };
