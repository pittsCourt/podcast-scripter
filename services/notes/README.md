# Notes service

The inbox behind the app's Story Queue, plus the RSS news shown in the editor sidebar. It grew out of x-post-archiver and imports that tool's `posts.json` the first time it starts.

- **X post links** are fetched through X's public oEmbed endpoint, which needs no API key. It only works for public posts, and gives the post date but not the time.
- **Other links** become articles, using the page's Open Graph tags for the title, summary, site name and image.
- **Other text** becomes a note.
- **News** comes from RSS/Atom feeds, refreshed every `FEED_INTERVAL_MINUTES` and kept for 14 days. The defaults are Google News searches for Real Salt Lake (team) and MLS (league).
- **Storage** is SQLite, using Node 24's built-in `node:sqlite`, at `data/notes.db`.

## Run

From the repo root:

```sh
docker compose up -d --build     # http://localhost:3030
docker compose logs -f notes
```

Settings come from the repo-root `.env` file, which is not committed:

| Variable | Used by |
|---|---|
| `NOTES_USER`, `NOTES_PASSWORD` | You, in a browser. The inbox page shows the browser's login prompt, and Safari can save it to Passwords. |
| `NOTES_TOKEN` | The Mac app and the iPhone Shortcut, sent as `Authorization: Bearer <token>` |
| `FEED_INTERVAL_MINUTES` | How often news feeds refresh (default 30; 0 turns it off) |

Either the login or the token works on every route except `/api/health`, which is always open. With none of them set, the service is open; only do that for local testing. After changing `.env`, run `docker compose up -d` to apply it.

The login is sent over plain HTTP. That's fine on your home network and over WireGuard, which encrypts the traffic, but don't expose port 3030 directly to the internet.

## API

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | No auth. `{ ok, version, authRequired }` |
| GET | `/api/items?status=inbox` | `inbox` (default), `used`, `dismissed`, or `all`. Newest first. |
| POST | `/api/items` | `{ "input": "<link or text>", "title"?: "..." }`. Returns 201 if new, or 200 with the existing item if the link was already saved (and moves it back to the inbox). JSON or form-encoded. |
| PATCH | `/api/items/:id` | `{ "status": "used" }`. The Mac app sets this when a story goes into a project. |
| DELETE | `/api/items/:id` | |
| GET | `/api/news?category=team&limit=20` | `team` or `league` |
| GET/POST | `/api/feeds` | POST takes `{ url, title, category }` |
| DELETE | `/api/feeds/:id` | |
| POST | `/api/feeds/refresh` | Fetches all feeds now |
| GET | `/api/standings?refresh=1` | MLS tables: `{ season, updatedAt, stale, conferences: [{ name, rows }], combined }`. The overall table is sorted by points, wins, goal difference, then goals for. |
| GET | `/api/matches?refresh=1` | The club's matches this season in every competition (MLS including playoffs, Leagues Cup, U.S. Open Cup, Concacaf Champions Cup): `{ season, team, competitions, results, upcoming, updatedAt, stale }`. Each match has `date, competition, stage, note, venue, broadcast, isHome, opponent, goalsFor, goalsAgainst, result (W/D/L), shootout (W/L on penalties), status`. |

Standings and matches come from ESPN's public JSON, which needs no key. They're cached for `STANDINGS_TTL_MINUTES` (default 30). `refresh=1` fetches fresh data, and the last good copy is served (with `stale: true`) if ESPN is down. The club is `TEAM_ESPN_ID` (default 4771, Real Salt Lake).

Items are camelCase JSON: `id, kind (x_post|article|note|news), status, title, body, url, source, authorName, handle, imageUrl, mediaLinks, category, postedOn, publishedAt, createdAt, updatedAt`.

Example:

```sh
curl -H "Authorization: Bearer $NOTES_TOKEN" -H "Content-Type: application/json" \
  -d '{"input":"https://x.com/realsaltlake/status/2098189245450264775"}' http://localhost:3030/api/items
```

## Projects

A project is one show about one team. Each has its own settings, inbox and history, news feeds, power-ranking history and weekly sync. `GET /api/projects` lists them; `POST /api/projects` with `{ name, fromProject?, team, show }` creates one, copying another project's settings when `fromProject` is given; `PATCH /api/projects/:id` takes `{ name?, makeDefault? }`; and `DELETE /api/projects/:id` deletes a project and everything stored for it. Every other `/api` route acts on the project named in the `X-Project` header or `?project=`, or the default project when neither is given (so existing Shortcuts keep working). Data from before projects is moved into the first project automatically on start. `.env` secrets (Gmail, Gemini, login) are shared by all projects.

## Settings

`GET /api/config` returns the show, script template, team (ESPN league and team ID), competitions, news searches and ranking-source settings. `PUT /api/config` saves a full copy (validated), `POST /api/config/reset` restores the defaults, and `GET /api/config/defaults` shows them. Defaults come from `config.default.json`; saved changes live in the database. `GET /api/espn/teams?league=usa.1` lists a league's teams for the Settings picker. Changing the team clears cached standings and matches, the news searches update the Google News feeds, and the weekly schedule restarts. Passwords and tokens stay in `.env`.

## Gemma

The service calls Gemma through the Gemini API (Google AI Studio; the default, needs `GEMINI_API_KEY` in `.env`) or a local Ollama model, set in Settings → AI (`config.ai`). Default models: `gemma-4-26b-a4b-it` on the Gemini API, `gemma4:12b` on Ollama.

| Endpoint | What it does |
|---|---|
| `GET /api/ai/status`, `POST /api/ai/test` | Which provider and model are active, whether the key is set, and a quick round trip |
| `POST /api/ai/ask` | `{ question, history, app }`: answers questions about the show. The app sends scripts and the Story Tracker; the service adds the queue, news, tables, matches and rankings. |
| `POST /api/ai/suggest-story` | `{ excerpt, episode, stories }`: which tracked story a passage belongs to, a one-line update, and any contradiction with earlier mentions |
| `POST /api/ai/briefing` | `{ episode, stories }`: per story, what's been said so far and what's new in the queue and news |
| `POST /api/ai/intro-bullets` | `{ episode }`: the three top-story bullets for the intro |

Requests are kept under `ai.contextChars` characters (default 60,000, about 15K tokens). Scripts are cut down to the passages that match the question, so the requests stay inside the Gemini API's free-tier limits.

## Power rankings

`POST /api/rankings/sync` fetches RSL's rank from five sources and saves a dated snapshot of each in the `ranking_snapshots` table, tagged with its season (the calendar year). Snapshots are kept forever, and articles and emails already read are skipped. `GET /api/rankings?season=2026` returns one season (the current one by default): `season`, `seasons` (every season with data), and per source `latest`, `previousRank`, `history` and the last sync `error`. The Mac app syncs when it opens and when you click Sync, and the inbox page has a **Sync now** button. The service also syncs once a week on `RANKINGS_SYNC_SCHEDULE` in `RANKINGS_SYNC_TZ`. The defaults are `Tue 16:00` in `UTC`, which is 10 a.m. MDT, when TacticsFreeZone's email has arrived. Using UTC keeps daylight saving from moving it: it's 9 a.m. when Mountain time is on MST. If the machine was asleep or the service was down at that time, it runs as soon as it's back. Set `RANKINGS_SYNC_SCHEDULE=` (empty) to turn it off.

| Source | How | History |
|---|---|---|
| MLS | Power-rankings topic page, then each article's 30 ranking headers, in order | Backfilled from every article this season |
| ESPN | ESPN search API, then each article's "21. Real Salt Lake … Previous ranking: 19" | Backfilled |
| TacticsFreeZone | Gmail over IMAP: emails from `tacticsfreezone@ghost.io` with "Power Rankings" in the subject, plus ones forwarded from `TFZ_FORWARDED_FROM` (each dated by its original send date) | Backfilled from the emails in the account |
| Concacaf | The Concacaf Club Ranking table, published by Hypercube | Recorded from the first sync on |
| Opta | RSL's entry in the data behind Opta's interactive table | Recorded from the first sync on |

Gmail needs `GMAIL_USER` and `GMAIL_APP_PASSWORD` in `.env`. Create the app password at Google Account → Security → 2-Step Verification → App passwords; if it contains `$`, wrap it in single quotes. Each source fails on its own without blocking the others. The Opta reader depends on how Opta's page is built and is the most likely to break.

## Running it elsewhere (server, Raspberry Pi)

The image is based on `node:24-alpine`, which is published for Intel/AMD (amd64) and ARM (arm64, armv7). Storage uses Node's built-in SQLite, so nothing has to be compiled. That means the same `docker compose up -d --build` works on this Mac, a Linux server, or a Raspberry Pi. On a Pi, use the 64-bit Raspberry Pi OS, and plan on a few minutes for the first build.

## Moving to the OptiPlex later

Copy the repo, or just `docker-compose.yml`, `.env` and `services/notes/`, to the server, including `services/notes/data/` to keep the inbox. Then run `docker compose up -d --build` there. Point the Mac app (Settings, ⌘,) and the iPhone Shortcut at `http://192.168.10.135:3030`.
