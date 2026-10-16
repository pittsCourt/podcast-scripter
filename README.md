# Podcast Scripter

A native macOS app (SwiftUI) for writing podcast scripts: projects with a script editor, a story queue, a story tracker, and power rankings. The story queue and news come from the notes service in `services/notes`, a small Docker app you can send links and notes to from your phone.

## Requirements

macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed, and the app has no third-party dependencies.

## Run

```sh
swift run                         # dev build, launches the app
./scripts/build-app.sh            # builds build/Podcast Scripter.app
./scripts/build-app.sh --install  # ...and copies it to /Applications
```

The app expects the notes service at `http://localhost:3030`. Change the address or token in Settings (⌘,). Without the service, the app still works and shows the last synced queue.

```sh
docker compose up -d --build      # start the notes service (needs Docker and a .env with NOTES_TOKEN)
```

See `services/notes/README.md` for the service, and `docs/iphone-shortcut.md` to send things from your iPhone's share menu.

Projects, tracked stories and a cached copy of the queue are stored at `~/Library/Application Support/PodcastScripter/data.json`. Set `PODCAST_SCRIPTER_DATA=/some/file.json` to use a different file (useful for testing).

## Layout

- `Sources/PodcastScripter/Models`: `Project`, `StoryItem`, `TrackedStory`, rankings and news
- `Sources/PodcastScripter/Services/NotesService.swift`: the `NotesService` protocol and its HTTP client, plus mock power rankings, which have no backend yet
- `services/notes/`: the notes service (Node + SQLite, in Docker)
- `docs/`: setup guides
- `Sources/PodcastScripter/Store/AppStore.swift`: app state, JSON persistence, navigation
- `Sources/PodcastScripter/Views`: home dashboard, editor, toolbar rankings banner, theme (`Theme.swift` holds colors and shared components)
- `designs/`: the original mockups
