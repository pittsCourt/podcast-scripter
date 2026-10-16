# Podcast Scripter

A Mac app for writing a sports podcast, and a small companion service that collects everything the show needs. Built for the *RSL Riot Report*; set up for any team, league or show.

- **Write scripts** in a formatted editor (headings, quotes, links). Each new script starts from your show's template: sections, intro and outro.
- **Collect stories** from your phone's share menu: X posts, articles and quick notes land in a Story Queue. Pick stories for an episode and they come with you into the script.
- **Follow running stories** in a Story Tracker. Highlight a passage to track it, and mark passages or whole stories as 🔴 rumor, 🟡 reported or 🟢 confirmed as they develop.
- **Stay current:** team and league news, the league table, the club's matches in every competition, and power rankings from five sources graphed over the season.
- **Ask Gemma** (Google's Gemma 4) about anything in the app: past scripts, tracked stories, the queue, results, rankings. Every answer lists exactly what it was given, so you can check it. Gemma also drafts intro bullets, briefs you on tracked stories, and suggests where a passage belongs.
- **Projects:** run several shows, each about a different team, with their own scripts, stories, news and settings.

## How it fits together

```
 Mac app (SwiftUI)                       Notes service (Node + SQLite, in Docker)
 ─────────────────                       ────────────────────────────────────────
 scripts, Story Tracker,      HTTP       story inbox + history, news feeds,
 editor, Ask Gemma       ◀──────────▶    standings & matches (ESPN), power rankings,
 (data on this Mac)        :3030          settings per project, Gemma requests
                                                  ▲            ▲
 iPhone Shortcut / inbox web page ───────────────┘            │ Gmail (IMAP), Gemini API
```

The Mac app keeps scripts and the Story Tracker on your Mac. Everything else lives in the notes service, which can run on the same Mac or on an always-on server or Raspberry Pi so your phone can reach it any time.

## Requirements

- **Mac app:** macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed, and there are no third-party Swift dependencies.
- **Notes service:** Docker (Docker Desktop on a Mac; Docker Engine on Linux or a Raspberry Pi). The image runs on Intel/AMD and ARM, including the 64-bit Raspberry Pi OS.

## Getting started on a Mac

```sh
git clone git@github.com:pittsCourt/podcast-scripter.git
cd podcast-scripter

# 1. Settings and passwords for the notes service (never committed)
cp services/notes/.env.example .env
#    edit .env: at least NOTES_USER, NOTES_PASSWORD and NOTES_TOKEN (openssl rand -hex 24);
#    add GEMINI_API_KEY for Gemma and the Gmail lines for TacticsFreeZone rankings.

# 2. Start the notes service
docker compose up -d --build        # http://localhost:3030

# 3. Run the app
swift run                           # or: ./scripts/build-app.sh --install  (copies it to Applications)
```

In the app, open **Project Settings** (the user icon, or ⌘,) → **Notes Service** and enter the address (`http://localhost:3030`) and your `NOTES_TOKEN`. Then set up your show in the other tabs: **Show**, **Script Template**, **Team & League**, **Power Rankings** and **AI**.

To send stories from your phone, follow [docs/iphone-shortcut.md](docs/iphone-shortcut.md).

## Running the notes service on a server or Raspberry Pi

The service doesn't need the app. On the server, download only `services/notes` with a sparse checkout:

```sh
# Docker on Raspberry Pi OS (64-bit) / Debian / Ubuntu, if it isn't installed yet:
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER        # then log out and back in

# Get just the service
git clone --filter=blob:none --no-checkout git@github.com:pittsCourt/podcast-scripter.git
cd podcast-scripter
git sparse-checkout set services/notes
git checkout main
cd services/notes

# Configure and start
cp .env.example .env                 # fill in, as on the Mac
docker compose up -d --build         # first build on a Pi takes a few minutes
docker compose logs -f               # "notes service … listening on port 3000"
```

If the repository is private, the server needs access to it: an SSH key added to your GitHub account (or a read-only deploy key on the repository), or clone over HTTPS with a personal access token. For a public repository, `https://github.com/pittsCourt/podcast-scripter.git` works without any setup.

Then point everything at the server's address, e.g. `http://192.168.10.135:3030`:

- **Mac app:** Project Settings → Notes Service → Address, then **Connect & Test**.
- **iPhone Shortcut:** change the URL in its *Get Contents of URL* step.
- **Inbox page:** open the new address in Safari and log in.

**Updating the server:**

```sh
cd podcast-scripter/services/notes
git pull
docker compose up -d --build
```

**Moving your data from the Mac to the server.** Everything the service stores (inbox history, news, power-ranking history, per-project settings) is in `services/notes/data/`. Stop the service on both machines, copy the folder over, and start it on the server:

```sh
# on the Mac
docker compose down
scp -r services/notes/data/ you@server:~/podcast-scripter/services/notes/
# on the server
docker compose up -d
```

Scripts and the Story Tracker stay in the Mac app (`~/Library/Application Support/PodcastScripter/data.json`) and don't need moving.

**Reaching it from anywhere.** Keep port 3030 on your home network and connect from outside over a VPN (e.g. WireGuard) rather than exposing it to the internet. The login and token are sent over plain HTTP. On a Mac running the service, a VPN app may also need to allow local network connections.

**Backups.** Back up `services/notes/data/` (the SQLite database) and the Mac app's `data.json`. Your `.env` holds the passwords and keys.

## Using it

- **Home:** Scripts on the left; Story Queue and Tracker, and team and league news, in the middle; drag the borders to resize. Check stories, then **New Script** or **Add to Script…**.
- **Editor:** formatting bar and Format menu (⌘B/I/U, ⌥⌘0–4 headings, ⌘K links). Highlight text to **Track Story** (⇧⌘T) or mark it 🔴/🟡/🟢 (⌃⌥1–3). **Draft Bullets** writes the intro's top stories; the sidebar's **Briefing** summarizes tracked stories. **Download** as RTF, Markdown or plain text.
- **Sidebar** (⌃⌘S): league table, the club's matches in every competition (with a filter), power-ranking graphs, and **Ask** for questions to Gemma.
- **Projects:** the name at the left of the toolbar switches projects or creates one for another team.
- **Zoom:** ⌘+ / ⌘− / ⌘0.

### Gemma

Gemma runs through the notes service: on the Gemini API (the default; set `GEMINI_API_KEY` from [Google AI Studio](https://aistudio.google.com)) or a local model with [Ollama](https://ollama.com). Choose under Project Settings → **AI**, where **Test Gemma** checks it. With each question Gemma gets a compact summary of the app's data plus the script passages that match, within a size limit you can adjust. It's told to answer only from that, to say when something isn't there, and to keep rumors, reports and confirmed facts apart. The **Sources** list under each answer shows exactly what it saw.

## Adapting it to another team or show

Everything specific to one show is a setting, not code. In the app, create a **New Project** (pick the league and team from ESPN's list) or edit Project Settings. For a fresh install, edit `services/notes/config.default.json`; those are the defaults until changed in Settings.

What carries over: standings, matches and competitions work for any ESPN soccer league and team, and news, the template and show details are free-form. The five power-ranking sources each have a reader built for one publication (MLSsoccer.com, ESPN's MLS column, TacticsFreeZone, Concacaf, Opta); other leagues can turn them off, and a new publication needs a new reader in `services/notes/src/rankings.js`. The table layout assumes soccer stats.

## Development

```sh
swift run                       # run the app
./scripts/test.sh               # tests (works without Xcode)
./scripts/build-app.sh          # build "Podcast Scripter.app" into ./build
docker compose up -d --build    # rebuild and restart the notes service after changes
```

`PODCAST_SCRIPTER_DATA=/some/file.json swift run` uses a different data file, handy for testing.

| Path | What's there |
|---|---|
| `Sources/PodcastScripter/Store/AppStore.swift` | App state, projects, local saving, talking to the service |
| `Sources/PodcastScripter/Views/` | Home, editor, sidebar, settings and theme |
| `Sources/PodcastScripter/Views/Editor/` | The formatted editor, status marks, template, Gemma sheets |
| `Sources/PodcastScripter/Services/NotesService.swift` | The service's API, as Swift |
| `services/notes/` | The notes service: `src/` code, `public/` inbox page, `config.default.json`, its own `docker-compose.yml` and `.env.example`, and [its README](services/notes/README.md) with the API |
| `docs/` | The iPhone Shortcut guide |
| `Tests/` | App tests |
