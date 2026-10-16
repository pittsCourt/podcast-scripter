// assistant.js
// The Gemma features. The Mac app sends what only it has (scripts, projects, the Story
// Tracker); this adds what the service has (story queue, news, table, matches, power
// rankings), keeps it within the size budget in Settings, and asks Gemma.
//
//   ask             questions about anything in the app ("what did we say about Luna in August?")
//   suggestStory    which tracked story a highlighted passage belongs to, a one-line update,
//                   and any contradiction with what was said before
//   briefing        per tracked story: what's been said so far, plus anything new in queue/news
//   introBullets    the episode's three top-story bullets

const ai = require('./ai');
const config = require('./config');
const db = require('./db');
const { getStandings, getMatches } = require('./espn');
const rankings = require('./rankings');

const STOPWORDS = new Set(('the and for with that this from what when where which about have has had were was are our your their they them then than into over after before just been will would could should there here also more most much very some such only other these those does did doing what whats who whom whose why how’s'.split(' ')));

const count = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const budget = () => Math.max(10000, Number((config.get().ai || {}).contextChars) || 60000);
const day = (d) => (d ? String(d).slice(0, 10) : '');
const clip = (text, n) => (text && text.length > n ? `${text.slice(0, n - 1)}…` : text || '');

function persona() {
  const { show, team } = config.get();
  return `You are the research assistant for "${show.fullName}", a podcast about ${team.name} hosted by ${show.host}. `
    + `Today is ${new Date().toDateString()}. Answer only from the information provided below; if it isn't there, say you don't have it. `
    + 'Be concise and specific. When you use something from a script, name the episode and its date.';
}

/** Lowercase keywords from a question, for picking relevant script passages. */
function keywords(text) {
  return [...new Set((text || '').toLowerCase().match(/[a-zà-ÿ0-9']{3,}/g) || [])].filter((w) => !STOPWORDS.has(w));
}

// --- service-side context (compact lines) ---

/** The service's data as labeled sections: { label, detail, text }. */
async function serviceParts({ includeHistory = true } = {}) {
  const { team } = config.get();
  const parts = [];
  const add = (label, detail, text) => parts.push({ label, detail, text });

  const queue = db.listInbox({ status: 'inbox' }).slice(0, 25);
  if (queue.length) {
    add('Story Queue', count(queue.length, 'item'), 'STORY QUEUE (saved, not yet used):\n' + queue.map((i) => `- [${i.kind}] ${i.title}: ${clip(i.body, 220)} (${day(i.createdAt)})`).join('\n'));
  }
  if (includeHistory) {
    const used = db.listInbox({ status: 'used' }).slice(0, 25);
    if (used.length) add('Stories already used', count(used.length, 'item'), 'STORIES ALREADY USED IN EPISODES:\n' + used.map((i) => `- ${i.title}: ${clip(i.body, 160)} (${day(i.createdAt)})`).join('\n'));
  }

  for (const [category, label] of [['team', `${team.shortName} NEWS`], ['league', 'LEAGUE NEWS']]) {
    const news = db.listNews({ category, limit: 15 });
    if (news.length) add(category === 'team' ? `${team.shortName} news` : 'League news', count(news.length, 'headline'), `${label} (headlines):\n` + news.map((n) => `- ${n.title} — ${n.source} (${day(n.publishedAt || n.createdAt)})`).join('\n'));
  }

  try {
    const standings = await getStandings();
    for (const conf of standings.conferences) {
      add(`${conf.name} table`, standings.season, `${conf.name.toUpperCase()} TABLE (${standings.season}): rank team P W D L GD Pts\n`
        + conf.rows.map((r) => `${r.rank}. ${r.team} ${r.played} ${r.wins} ${r.draws} ${r.losses} ${r.goalDifference > 0 ? '+' : ''}${r.goalDifference} ${r.points}`).join('\n'));
    }
    const overall = standings.combined.find((r) => r.abbreviation === team.shortName);
    if (overall) add('Overall table', `${team.shortName} ${overall.rank} of ${standings.combined.length}`, `${team.name} is ${overall.rank} of ${standings.combined.length} in the overall table.`);
  } catch { /* standings unavailable: skip */ }

  try {
    const matches = await getMatches();
    const line = (m) => `${day(m.date)} ${m.competition}${m.stage && m.stage !== 'Regular Season' ? ` (${m.stage})` : ''}: ${m.isHome ? 'vs' : 'at'} ${m.opponent.name}`;
    if (matches.results.length) {
      add('Results', count(matches.results.length, 'match', 'matches'), 'RESULTS (newest first, score is ours–theirs):\n' + matches.results.map((m) => `${line(m)} ${m.goalsFor}–${m.goalsAgainst} ${m.result}${m.shootout ? ` (${m.shootout} on penalties)` : ''}`).join('\n'));
    }
    if (matches.upcoming.length) {
      add('Upcoming matches', count(matches.upcoming.length, 'match', 'matches'), 'UPCOMING MATCHES:\n' + matches.upcoming.map((m) => `${line(m)}${m.broadcast ? ` [${m.broadcast}]` : ''}`).join('\n'));
    }
  } catch { /* matches unavailable: skip */ }

  const ranks = rankings.summary();
  const rankLines = ranks.sources.filter((s) => s.latest).map((s) => {
    const history = s.history.map((p) => `${p.date.slice(5)}:${p.rank}`).join(' ');
    return `- ${s.name}: now ${s.latest.rank}${s.previousRank ? ` (previously ${s.previousRank})` : ''}; season: ${history}`;
  });
  if (rankLines.length) add('Power rankings', `${count(rankLines.length, 'source')}, ${ranks.season}`, `POWER RANKINGS (${ranks.season}, MM-DD:rank):\n` + rankLines.join('\n'));

  return parts;
}

async function serviceContext(options) {
  return (await serviceParts(options)).map((p) => p.text).join('\n\n');
}

/** Joins parts within `limit` characters, reporting which made it in (whole or cut short). */
function fitParts(parts, limit) {
  let text = '';
  const included = [];
  for (const part of parts) {
    const sep = text ? '\n\n' : '';
    const room = limit - text.length - sep.length;
    if (room < 80) break;
    if (part.text.length <= room) {
      text += sep + part.text;
      included.push({ label: part.label, detail: part.detail });
    } else {
      text += sep + clip(part.text, room);
      included.push({ label: part.label, detail: `${part.detail}, shortened to fit` });
      break;
    }
  }
  return { text, included };
}

// --- app-side context ---

function trackerText(stories = [], limit) {
  const blocks = stories.map((s) => {
    const mentions = (s.mentions || []).map((m) => `  - ${m.episode} (${day(m.date)}): "${clip(m.excerpt, 300)}"${m.note ? ` — note: ${m.note}` : ''}`);
    return `* ${s.title}${s.latestUpdate ? ` — latest: ${clip(s.latestUpdate, 200)}` : ''}${mentions.length ? `\n${mentions.join('\n')}` : ''}`;
  });
  return clip('STORY TRACKER:\n' + blocks.join('\n'), limit);
}

/** Script paragraphs that best match the question, labeled with their episode, within `limit`. */
function relevantScripts(projects, question, limit) {
  return pickScripts(projects, question, limit).text;
}

/** Script paragraphs that best match the question, plus which ones were picked (for Sources). */
function pickScripts(projects = [], question, limit) {
  const words = keywords(question);
  const list = projects.map((p) => `- ${p.name} (${day(p.date)}), ${(p.script || '').split(/\s+/).filter(Boolean).length} words`);
  let text = `EPISODES (${projects.length}):\n${list.join('\n')}`;

  const paragraphs = projects.flatMap((p) => (p.script || '').split(/\n+/).map((t) => t.trim())
    .filter((t) => t.length > 30)
    .map((t, i) => ({ t, p, i, score: words.reduce((n, w) => n + (t.toLowerCase().includes(w) ? 1 : 0), 0) })));
  // With no matching words (e.g. "summarize the season"), lean on the newest episodes.
  const ranked = words.length && paragraphs.some((x) => x.score > 0)
    ? paragraphs.filter((x) => x.score > 0).sort((a, b) => b.score - a.score || String(b.p.date).localeCompare(String(a.p.date)))
    : paragraphs.sort((a, b) => String(b.p.date).localeCompare(String(a.p.date)) || a.i - b.i);

  const picked = [];
  const excerpts = [];
  let used = text.length + 40;
  for (const x of ranked) {
    const line = `[${x.p.name}, ${day(x.p.date)}] ${x.t}`;
    if (used + line.length > limit) break;
    picked.push(line);
    excerpts.push({ episode: x.p.name, date: day(x.p.date), text: x.t });
    used += line.length + 1;
  }
  if (picked.length) text += `\n\nSCRIPT EXCERPTS:\n${picked.join('\n')}`;
  return { text, excerpts, episodes: projects.length };
}

// --- features ---

async function ask({ question, history = [], app = {} }) {
  if (!question || !question.trim()) throw Object.assign(new Error('Ask a question.'), { status: 400 });
  const total = budget();
  const service = fitParts(await serviceParts(), Math.floor(total * 0.35));
  const stories = app.trackedStories || [];
  const trackerLimit = Math.floor(total * 0.2);
  const tracker = trackerText(stories, trackerLimit);
  const scripts = pickScripts(app.scripts || app.projects, `${question} ${history.map((h) => h.content).join(' ')}`, total - service.text.length - tracker.length);

  const conversation = history.slice(-6).map((h) => `${h.role === 'assistant' ? 'Assistant' : 'Host'}: ${clip(h.content, 1500)}`).join('\n');
  const prompt = `${service.text}\n\n${tracker}\n\n${scripts.text}\n\n${conversation ? `CONVERSATION SO FAR:\n${conversation}\n\n` : ''}Host's question: ${question}`;
  const reply = await ai.generate({ system: persona(), prompt, temperature: 0.2 });

  // Exactly what Gemma was given, so every answer can be checked.
  const trackerFull = trackerText(stories, Infinity).length <= trackerLimit;
  return {
    answer: reply.text,
    model: reply.model,
    provider: reply.provider,
    ms: reply.ms,
    sources: {
      excerpts: scripts.excerpts,
      episodes: scripts.episodes,
      stories: stories.map((st) => ({ title: st.title, mentions: (st.mentions || []).length })),
      storiesShortened: !trackerFull,
      data: service.included,
    },
  };
}

async function suggestStory({ excerpt, episode = {}, stories = [] }) {
  if (!excerpt || !excerpt.trim()) throw Object.assign(new Error('No passage to check.'), { status: 400 });
  const tracker = trackerText(stories.map((s) => ({ ...s, mentions: (s.mentions || []).slice(-4) })), Math.floor(budget() * 0.6));
  const ids = stories.map((s) => `${s.id} = ${s.title}`).join('\n');
  const prompt = `${tracker}\n\nSTORY IDS:\n${ids || '(none yet)'}\n\n`
    + `New passage from "${episode.name || 'this episode'}" (${day(episode.date)}):\n"""${clip(excerpt, 3000)}"""\n\n`
    + 'Decide which tracked story this passage belongs to (or that it is a new story), write a one-line update '
    + 'summarizing the new information (max 20 words), and point out anything that contradicts an earlier mention '
    + '(e.g. a different return date). Reply with JSON only, no prose: '
    + '{"storyId": "<id from STORY IDS or null>", "newTitle": "<short title if new, else null>", '
    + '"update": "<one line>", "contradiction": "<one sentence, or null>"}';
  const reply = await ai.generate({ system: persona(), prompt, json: true, temperature: 0.1 });
  const parsed = ai.parseJSON(reply.text);
  // Match IDs case-insensitively; models sometimes change the case.
  const match = stories.find((s) => String(s.id).toLowerCase() === String(parsed.storyId || '').toLowerCase());
  return {
    storyId: match ? match.id : null,
    newTitle: parsed.newTitle || null,
    update: parsed.update || '',
    contradiction: parsed.contradiction && String(parsed.contradiction).toLowerCase() !== 'null' ? parsed.contradiction : null,
    model: reply.model,
  };
}

async function briefing({ episode = {}, stories = [] }) {
  if (!stories.length) return { briefings: [], model: null };
  const queue = db.listInbox({ status: 'inbox' });
  const news = [...db.listNews({ category: 'team', limit: 40 }), ...db.listNews({ category: 'league', limit: 40 })];
  const newItems = (story) => {
    const words = keywords(story.title).filter((w) => w.length > 3);
    const hit = (t) => words.some((w) => t.toLowerCase().includes(w));
    return [...queue, ...news].filter((i) => hit(`${i.title} ${i.body}`)).slice(0, 6)
      .map((i) => `    - ${i.kind === 'news' ? 'news' : 'queue'}: ${i.title}${i.body ? ` — ${clip(i.body, 160)}` : ''} (${day(i.publishedAt || i.createdAt)})`);
  };
  const blocks = stories.map((s) => {
    const fresh = newItems(s);
    return `${trackerText([s], 4000).replace('STORY TRACKER:\n', '')}\n  id: ${s.id}${fresh.length ? `\n  NEW SINCE (queue and news):\n${fresh.join('\n')}` : ''}`;
  });
  const prompt = `Episode being written: "${episode.name || ''}" (${day(episode.date)}).\n\nTRACKED STORIES:\n${clip(blocks.join('\n\n'), budget())}\n\n`
    + 'For each story, write a briefing for the host: "summary" = what the show has said so far, in 1-2 sentences; '
    + '"whatsNew" = anything new from the queue/news since then in 1 sentence, or null. Reply with JSON only: '
    + '{"briefings": [{"storyId": "<id>", "summary": "...", "whatsNew": "... or null"}]}';
  const reply = await ai.generate({ system: persona(), prompt, json: true, temperature: 0.2 });
  const parsed = ai.parseJSON(reply.text);
  const list = Array.isArray(parsed) ? parsed : parsed.briefings || [];
  return {
    briefings: list.filter((b) => b && b.storyId).map((b) => ({
      storyId: (stories.find((s) => String(s.id).toLowerCase() === String(b.storyId).toLowerCase()) || { id: String(b.storyId) }).id,
      summary: b.summary || '',
      whatsNew: b.whatsNew && String(b.whatsNew).toLowerCase() !== 'null' ? b.whatsNew : null,
    })),
    model: reply.model,
  };
}

async function introBullets({ episode = {} }) {
  const { team } = config.get();
  const stories = (episode.stories || []).map((s) => `- [${s.kind}] ${s.title}: ${clip(s.body, 300)}`).join('\n');
  const service = clip(await serviceContext({ includeHistory: false }), Math.floor(budget() * 0.5));
  const script = clip(episode.script || '', Math.floor(budget() * 0.3));
  const prompt = `${service}\n\nSTORIES PICKED FOR THIS EPISODE:\n${stories || '(none)'}\n\nSCRIPT SO FAR:\n${script || '(empty)'}\n\n`
    + `Write exactly three top-story bullets for the intro of the episode dated ${day(episode.date)}. Rules: short, punchy `
    + `one-liners; ranked by importance across all sections; ${team.name}'s most recent match result is normally #1; `
    + 'stories marked [top] take priority. Reply with JSON only: {"bullets": ["...", "...", "..."]}';
  const reply = await ai.generate({ system: persona(), prompt, json: true, temperature: 0.4 });
  const parsed = ai.parseJSON(reply.text);
  const bullets = (Array.isArray(parsed) ? parsed : parsed.bullets || []).map(String).filter(Boolean).slice(0, 3);
  if (bullets.length !== 3) throw new Error('Gemma didn’t return three bullets. Try again.');
  return { bullets, model: reply.model };
}

module.exports = { ask, suggestStory, briefing, introBullets, keywords, relevantScripts, pickScripts, fitParts };
