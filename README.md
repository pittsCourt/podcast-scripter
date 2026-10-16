# Podcast Scripter

A native macOS app (SwiftUI) for writing podcast scripts: projects with a script editor, a story queue, a story tracker, instruction files, and power rankings / news from a pluggable news service.

## Requirements

macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed, and the app has no third-party dependencies.

## Run

```sh
swift run                         # dev build, launches the app
./scripts/build-app.sh            # builds build/Podcast Scripter.app
./scripts/build-app.sh --install  # ...and copies it to /Applications
```

Data is stored at `~/Library/Application Support/PodcastScripter/data.json`. Set `PODCAST_SCRIPTER_DATA=/some/file.json` to use a different file (useful for testing).

## Layout

- `Sources/PodcastScripter/Models`: `Project`, `StoryItem`, `TrackedStory`, `InstructionFile`, rankings and news
- `Sources/PodcastScripter/Services/NewsService.swift`: the `NewsService` protocol plus `MockNewsService`. Replace the mock with the real notes service when it exists.
- `Sources/PodcastScripter/Store/AppStore.swift`: app state, JSON persistence, navigation
- `Sources/PodcastScripter/Views`: home dashboard, editor, top bar, theme
- `designs/`: the original mockups
