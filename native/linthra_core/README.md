# linthra_core (Rust)

`linthra_core` is the Rust core that holds Linthra's decision logic. It searches very large catalogs without making Flutter walk 100,000–200,000 track objects for every keystroke, groups the catalog into albums and artists, and decides which cached tracks to delete when a download needs room.

## Current scope

- dependency-free Rust core
- immutable inverted index
- title / artist / album / album-artist / provider tokens
- accent-folded, case-folded tokens, so `bjork` finds `Björk`
- prefix search with AND semantics across query terms
- deterministic ranking
- synthetic 200,000-track regression benchmark
- cache eviction policy (`src/cache_eviction.rs`): which cached tracks to delete so a download fits, held to the same cases as the Dart policy (`test/fixtures/cache_eviction_cases.json`)
- album and artist grouping (`src/library_grouping.rs`): the Library's albums and artists, their order, and the same ids `albumIdForTrack` / `artistIdForTrack` compute in Dart. Dart lower-cases the names before they cross, because its case table is not Rust's. `test/core/catalog/library_grouping_native_test.dart` checks both paths agree, on every code point
- download rules (`src/download_gate.rs`, `src/download_state.rs`): whether the network lets a download run, how a cancelled download settles its row, and whether a held download is retried or dropped, each held to the same cases as Dart (`test/fixtures/download_*_cases.txt`)
- playback queue (`src/queue_moves.rs`, `src/queue_edits.rs`): next/previous/jumps, play next, add to queue, remove, reorder, remove-where, shuffle and unshuffle, on entry ids. The shuffle is splitmix64-driven Fisher-Yates, seeded by Dart, so both sides give the same order (`test/fixtures/queue_*_cases.txt`)

## How Flutter uses it

The crate is built into the app by a Dart build hook, with no download and no prebuilt binary:

- `hook/build.dart` (repo root) runs `cargo build --release --locked --offline` for the target being built and bundles `liblinthra_core.so` as a code asset. `flutter run`, `flutter build` and `flutter test` all run it.
- `src/ffi.rs` is the C ABI, with the eviction calls in `src/ffi/cache_eviction.rs`, the grouping call in `src/ffi/library_grouping.rs` the download rules in `src/ffi/downloads.rs` and the queue in `src/ffi/queue.rs`. `lib/core/native/linthra_core_ffi.dart` declares the same functions with `@Native`. Change them together and bump `ABI_VERSION` in `ffi.rs` and `LinthraCore.abiVersion` in `lib/core/native/linthra_core.dart`.
- `lib/core/native/linthra_core.dart` is what the rest of the app uses: `LinthraCore.isAvailable` and `NativeSearchIndex`. `CacheEvictionPolicy` calls `lib/core/native/native_cache_eviction.dart` itself, and `groupAlbums` / `groupArtists` / `groupLibrary` call `lib/core/native/native_library_grouping.dart`, and `downloadGate` / `settleCanceled` / `heldAction` call `lib/core/native/native_downloads.dart`, and `PlaybackQueue` calls `lib/core/native/native_queue.dart`, so their callers need not know which path ran.

The Rust core is **optional for now**. When `cargo`/`rustc` are missing, a Linux build has no `cc` to link with, or the Rust standard library for the target isn't installed, the hook skips the library and `LinthraCore.isAvailable` is false, so every caller has to keep a Dart fallback. A cargo build that starts and fails does fail the app build.

| Target | What the hook needs |
| --- | --- |
| Linux (x64, arm64) | `cargo`, `rustc` and a C linker (`cc`) |
| Android | the same, plus `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`; the hook links with the NDK's clang |

`cargo` is found on `PATH`, then in `$CARGO_HOME/bin` and `~/.cargo/bin`. CI runs `flutter test` with `LINTHRA_REQUIRE_RUST=1`, which turns a skipped library into a failing test (`test/core/native/linthra_core_test.dart`).

The Flatpak builds it through the `org.freedesktop.Sdk.Extension.rust-stable` SDK extension (`flatpak/flatpak-flutter.yml`).

The Android builds (GitHub, Google Play, Sponsor, and the CI debug APK) install the Rust pinned in `.rust-version` with the Android targets (`.github/actions/setup-rust-android`), and `scripts/check_apk_rust_core.py` fails a build whose APK lacks the library for an ABI.

Not covered yet: F-Droid. Its recipe lives in fdroiddata and has to install the same `.rust-version` before the first release built this way, or its build stops matching the signed APK it is checked against.

## Run it

```bash
cargo test --manifest-path native/linthra_core/Cargo.toml
cargo run --release --manifest-path native/linthra_core/Cargo.toml --bin benchmark_200k
```

The benchmark uses a generous 50 ms average-query regression ceiling so shared CI runners stay reliable. It is a guard against accidentally turning search into an O(full catalog) operation, not a claim that every device will have identical timings.

## Normalization

Metadata and queries go through the same tokenizer (`src/normalize.rs`), because a fold applied when building the index and not when searching it is worse than no fold at all. It splits on anything that is not alphanumeric, lower-cases, and folds accents.

**What folds.** Latin-1 Supplement and Latin Extended-A, plus the Combining Diacritical Marks block (U+0300–U+036F). That is where Western, Central and Northern European music metadata lives: `Björk`, `Motörhead`, `Beyoncé`, `Dvořák`, `Straße` (→ `strasse`), `Encyclopædia` (→ `encyclopaedia`).

Both spellings of the same text fold to the same token, whether the accent arrived precomposed (`ö`) or decomposed (`o` + U+0308). The decomposed form used to be split *on* the mark, so `Mötley` written that way became the two tokens `mo` and `tley` — the word came apart rather than merely losing its accent.

**What does not fold.** Greek, Cyrillic, Hebrew, Arabic, CJK and Hangul are indexed and searched unchanged. These are not scripts where a listener types the "unaccented" spelling of a name, so folding them would invent a behaviour nobody asked for. Vietnamese folds only as far as its precomposed characters reach into Latin Extended-A; its decomposed form folds fully through the combining-mark rule.

This is also why the crate still has no dependencies. A full Unicode normalization crate would buy correctness for the scripts the fold deliberately leaves alone, at the cost of the one property that makes this core easy to vendor and audit.

Folding is **not** fuzzy matching. It removes accents; it does not make near-misses match, and `motorhed` still finds nothing.

## Good contribution areas

Rust contributors can work here without knowing Flutter. Useful next steps include compact index serialization, incremental index updates, cross-provider duplicate candidates, per-album and per-artist track lookups, memory benchmarks, and the eventual stable Dart/Flutter FFI boundary.
