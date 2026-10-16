# Podcast Scripter

A native macOS app (SwiftUI) for writing podcast scripts: projects with a script editor, a story queue, a story tracker, and power rankings. The story queue and news come from the notes service in `services/notes`, a small Docker app you can send links and notes to from your phone.

## Requirements

macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed, and the app has no third-party dependencies.

## Run

```sh
swift run                         # dev build, launches the app
./scripts/build-app.sh            # builds build/Podcast Scripter.app
./scripts/build-app.sh --install  # ...and copies it to /Applications
./scripts/test.sh                 # runs the tests (works without Xcode)
```

The app expects the notes service at `http://localhost:3030`. Change the address or token in Settings (⌘,). Without the service, the app still works and shows the last synced queue.

```sh
docker compose up -d --build      # start the notes service (needs Docker and a .env with NOTES_TOKEN)
```

See `services/notes/README.md` for the service, and `docs/iphone-shortcut.md` to send things from your iPhone's share menu.

Projects, tracked stories and a cached copy of the queue are stored at `~/Library/Application Support/PodcastScripter/data.json`. Set `PODCAST_SCRIPTER_DATA=/some/file.json` to use a different file (useful for testing).

## Gemma

Gemma 4 runs through the notes service, either on the Gemini API (the default: put your Google AI Studio key in `.env` as `GEMINI_API_KEY`) or a local Ollama model. Choose in Settings → AI, where **Test Gemma** checks it.

- **Ask** tab in the right sidebar: questions about anything in the app (scripts, Story Tracker, queue, news, table, matches, rankings).
- **Track Story** in the editor: Gemma suggests which story the passage belongs to, drafts a one-line update, and flags contradictions with what you said before.
- **Briefing** in the editor sidebar: what you've said about each tracked story, plus anything new in the queue and news.
- **Draft Bullets** in the editor: the intro's three top-story bullets, filled into the template.

## Adapting it to another team or show

Everything specific to the RSL Riot Report is a setting, not code:

- **In the app:** open Settings (⌘,). It has tabs for the show (name, host, X handle), the script template (sections, intro and outro, with `{date}`, `{host}`, `{show}`, `{handle}`, `{team}`), the team and league (picked from ESPN), the competitions to track, the news searches, and the power-ranking sources and weekly sync time. Settings are saved in the notes service, so every device shares them.
- **For a fresh install:** edit `services/notes/config.default.json`. Those are the defaults until someone changes them in Settings, and "Reset to Defaults" goes back to them.

What carries over: standings, matches and competitions work for any ESPN soccer league and team, and news, the template and show details are free-form. The five power-ranking sources each have a reader built for one publication (MLSsoccer.com, ESPN's MLS column, TacticsFreeZone, Concacaf, Opta). Other leagues can turn them off; adding a different publication means writing a new reader in `services/notes/src/rankings.js`. The table layout assumes soccer stats (W/D/L, goal difference).

## Layout

- `Sources/PodcastScripter/Models`: `Project`, `StoryItem`, `TrackedStory`, rankings and news
- `Sources/PodcastScripter/Services/NotesService.swift`: the `NotesService` protocol and its HTTP client
- `Sources/PodcastScripter/Models/AppConfig.swift`: show, template, team and source settings (mirrors `services/notes/config.default.json`)
- `services/notes/`: the notes service (Node + SQLite, in Docker)
- `docs/`: setup guides
- `Sources/PodcastScripter/Store/AppStore.swift`: app state, JSON persistence, navigation
- `Sources/PodcastScripter/Views`: home dashboard, editor, toolbar rankings banner, theme (`Theme.swift` holds colors and shared components)
- `Sources/PodcastScripter/Views/Editor`: the formatted script editor (NSTextView), the format bar and Format menu, and RTF/Markdown conversion (`ScriptFormatting.swift`)
- `Tests/`: tests for formatting, saving and export
- `designs/`: the original mockups
