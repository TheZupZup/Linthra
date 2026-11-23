# Development

For anyone working on Linthra's code. New here? Read the setup, then the
codebase tour.

## Getting started

| Document | What it covers |
| --- | --- |
| [Setup](setup.md) | Building and running Linthra on Android and Linux |
| [Codebase tour](codebase-tour.md) | Where things live and how they connect |
| [Architecture](architecture.md) | The layers and the rules between them |
| [Contributing by language](language-areas.md) | Where Rust, Kotlin, C++ and Python each have a job |
| [Contributor roadmap](contributor-roadmap.md) | Where help is useful right now |
| [Maintainer map](maintainer-map.md) | The maintainer's own map of the project |

## How playback works

| Document | What it covers |
| --- | --- |
| [Unified library](unified-library.md) | Playing the same music from several sources at once |
| [Playback source strategy](playback-source-strategy.md) | Which copy plays when a song is on more than one provider |
| [Remote playback cache](remote-playback-cache.md) | Buffering ahead so remote playback does not cut out |

## Testing and maintenance

| Document | What it covers |
| --- | --- |
| [Manual test checklist](manual-test-checklist.md) | The Android checks the automated suite cannot do |
| [Dependency updates](dependency-updates.md) | The scheduled update pull requests and how to review them |
| [Flutter CI fixer](flutter-ci-fixer.md) | The guarded workflow that repairs failed Flutter checks |
| [Android 17](android-17.md) | What targeting API 37 changed |
