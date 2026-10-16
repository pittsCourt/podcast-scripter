// schedule.js
// Weekly automatic rankings sync, e.g. "Tue 10:00" in America/Denver.
// Checks once a minute; if the machine was asleep or the service was down at
// the scheduled time, it catches up the next time it's running. The last slot
// that ran is saved, so restarts don't re-run or skip a week.

const db = require('./db');

const DAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const store = db.connection;
store.exec('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)');

const getMeta = (key) => (store.prepare('SELECT value FROM meta WHERE key = ?').get(key) || {}).value || null;
const setMeta = (key, value) => store.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value').run(key, value);

/** Parses "Tue 10:00" -> { weekday: 2, hour: 10, minute: 0 }, or null to disable. */
function parseSchedule(text) {
  const m = (text || '').trim().toLowerCase().match(/^([a-z]{3})[a-z]*\s+(\d{1,2}):(\d{2})$/);
  if (!m || !DAYS.includes(m[1])) return null;
  return { weekday: DAYS.indexOf(m[1]), hour: Number(m[2]), minute: Number(m[3]) };
}

/** Wall-clock parts of `date` in `timeZone`. */
function partsIn(date, timeZone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
    timeZone, weekday: 'short', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(date).map((p) => [p.type, p.value]));
  return {
    weekday: DAYS.indexOf(parts.weekday.toLowerCase()),
    year: Number(parts.year), month: Number(parts.month), day: Number(parts.day),
    hour: Number(parts.hour), minute: Number(parts.minute),
  };
}

/** The most recent scheduled slot at or before now, as "YYYY-MM-DD HH:MM" local to the time zone. */
function latestSlot(schedule, timeZone, now = new Date()) {
  const p = partsIn(now, timeZone);
  let daysBack = (p.weekday - schedule.weekday + 7) % 7;
  if (daysBack === 0 && p.hour * 60 + p.minute < schedule.hour * 60 + schedule.minute) daysBack = 7;
  const day = new Date(Date.UTC(p.year, p.month - 1, p.day - daysBack));
  const pad = (n) => String(n).padStart(2, '0');
  return `${day.toISOString().slice(0, 10)} ${pad(schedule.hour)}:${pad(schedule.minute)}`;
}

function describe(schedule, timeZone) {
  if (!schedule) return null;
  const time = new Date(Date.UTC(2000, 0, 1, schedule.hour, schedule.minute))
    .toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' });
  const day = new Date(Date.UTC(2000, 0, 2 + schedule.weekday)).toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
  return `${day}s at ${time} (${timeZone})`;
}

let timers = [];

/**
 * Runs `job` on the weekly schedule, replacing any previous schedule (Settings can change it).
 * Returns info for the API.
 * @param {string} text  e.g. "Tue 16:00"; empty disables it
 */
function startWeekly(text, timeZone, job) {
  timers.forEach(clearTimeout);
  timers.forEach(clearInterval);
  timers = [];
  const schedule = parseSchedule(text);
  const info = { description: describe(schedule, timeZone), timeZone };
  if (!schedule) {
    if (text) console.warn(`rankings schedule "${text}" not understood; expected e.g. "Tue 10:00"`);
    return info;
  }

  const tick = async () => {
    const slot = latestSlot(schedule, timeZone);
    const last = getMeta('rankings.lastScheduledSlot');
    if (last === slot) return;
    const spec = `${text} ${timeZone}`;
    if (!last || getMeta('rankings.scheduleSpec') !== spec) {
      // First start, or the schedule was just changed: start counting from now
      // instead of treating the new slot as a missed run.
      setMeta('rankings.lastScheduledSlot', slot);
      setMeta('rankings.scheduleSpec', spec);
      return;
    }
    setMeta('rankings.lastScheduledSlot', slot);
    console.log(`scheduled rankings sync (${slot} ${timeZone})`);
    try {
      await job();
    } catch (err) {
      console.warn(`scheduled rankings sync failed: ${err.message}`);
    }
  };

  timers.push(setTimeout(tick, 5000));
  timers.push(setInterval(tick, 60000).unref());
  console.log(`rankings auto-sync: ${info.description}`);
  return info;
}

module.exports = { startWeekly, getMeta, setMeta, parseSchedule, latestSlot };
