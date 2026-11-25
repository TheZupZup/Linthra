# Contributing by language

Linthra is a Flutter app, but the project is deliberately becoming polyglot where a language has a real technical job. You do **not** need to learn Dart before you can make a meaningful contribution.

| Language | Owns / improves | Main area |
| --- | --- | --- |
| Dart / Flutter | UI, playback orchestration, providers, onboarding, cross-platform app logic | `lib/`, `test/` |
| Kotlin | Android platform integration, SAF/MediaStore, media session, Android Auto, system channels | `android/app/src/main/kotlin/` |
| Rust | large-library indexing/search, album/artist grouping, cross-provider duplicate merging, cache eviction, queue and download rules | `native/linthra_core/` |
| C++ | realtime audio DSP, EQ/limiting, future audio analysis and SIMD work | `native/linthra_audio/` |
| C++ / CMake (GTK) | the native Linux desktop runner: window identity and metadata, GTK application setup, native build configuration | `linux/` |
| Python | release tooling, large-library fixtures, benchmarks, validation | `scripts/`, `tool/`, `tools/` |
| SQL | SQLite schema/index/query performance for very large catalogs | `tools/large_library/schema.sql` and Drift/database work |

## Dart / Flutter

Choose Dart when the change is visible app behaviour: screens, navigation, source/provider flows, player state, caching policy, settings, or tests around those features. Flutter remains the product shell and orchestration layer.

## Kotlin / Android

Choose Kotlin when Android itself is the feature. Linthra already has native channels for scoped-storage scanning, launcher icons, sharing, connectivity, display refresh rate and media artwork. Android Auto/media-session work belongs here when it needs Android APIs rather than Flutter widgets.

## Rust / large libraries

`linthra_core` targets the work that becomes expensive at 100,000–200,000 tracks. Its first responsibility is indexed search with a synthetic 200k regression benchmark; it also groups the Library into albums and artists, merges the copies of a song that several servers serve, and plans cache evictions. Good follow-up areas include compact index persistence, incremental updates, grouping primitives, memory profiling and the eventual stable Flutter FFI boundary.

## C++ / audio DSP

`linthra_audio` owns realtime signal processing. The callback must stay bounded, allocation-free and lock-free. EQ, limiter behaviour, SIMD, channel layouts and loudness/peak analysis are useful C++ contribution areas. The current core is intentionally separated from the `just_audio` mobile binding so DSP math can be reviewed independently from Android playback plumbing.

## C++ / CMake / GTK — the Linux runner

`linux/` is the native entry point of the desktop app: a small GTK application that creates the window, sets Linthra's identity, and hands off to the Flutter engine. It is C++ because that is what the Flutter Linux embedder is; there is no Dart alternative for this layer.

Keep it small. Anything that could live in Dart should — the runner exists to create a correct window and get out of the way, not to hold product logic. Its build configuration (`linux/CMakeLists.txt`) is also where native-dependency decisions land, such as the SQLite pre-fetch seam that keeps the build possible with no network. See [Linux desktop](../linux/desktop.md).

## Python / tooling

Python should remove repetitive maintainer work or create useful developer fixtures. Linthra already uses Python in release/branding tooling; `tools/large_library/` adds deterministic 200k-track SQLite generation and query benchmarks using only the standard library. `scripts/check_linux_runner.py` is a good shape to copy: a config invariant that no compiler would catch, checked against its real sources of truth, with unit tests beside it.

Ruff lints and format-checks this code on every PR that touches it. Run `ruff check scripts tool tools` and `ruff format --check scripts tool tools` before pushing — those paths are the linted scope, and are what CI passes. The rules are in `ruff.toml` and the setup is described in [Development](setup.md#python-tooling-checks-ruff).

## SQL / database performance

SQL matters when a query that feels instant at 5,000 tracks becomes obvious at 200,000. Contributions should include the query plan and a representative fixture/benchmark when possible. Avoid adding indexes speculatively: each index costs storage and write time, so keep ones that serve measured access patterns.

## Cross-language rule

A language does not enter Linthra just to appear in GitHub's language bar. New native/tooling code should have a clear owner, tests or benchmarks, a small boundary to the rest of the app, and a reason it is better suited to that job than the existing layer.
