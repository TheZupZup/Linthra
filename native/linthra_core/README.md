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
- search results order (`src/search_rank.rs`): artists, albums and songs ranked in one list for the Library search's All view, by how each one's own name matches the query (word for word, whole words, starts of words, typos, or another field), then artist, album, song (`test/fixtures/search_rank_cases.txt`)
- playback queue (`src/queue_moves.rs`, `src/queue_edits.rs`): next/previous/jumps, play next, add to queue, remove, reorder, remove-where, shuffle and unshuffle, on entry ids. The shuffle is splitmix64-driven Fisher-Yates, seeded by Dart, so both sides give the same order (`test/fixtures/queue_*_cases.txt`)
- audio tags (`src/tags/`): FLAC, Ogg Vorbis, Opus, MP3 (ID3v2, ID3v1, APE), MP4, WAV, AIFF and Monkey's Audio, read by their specs for the local library, with a stress test that damaged files never panic (`test/fixtures/tags/`)
- playback rules (`src/playback_rules.rs`): what an engine error means (locations redacted first, by hand-written scanners that follow Dart's regular expressions), the failure and cause it records, whether to retry, move on or stop after a failure, and what an audio focus change asks for (`test/fixtures/playback_error_cases.txt`; `test/core/services/playback_rules_parity_test.dart` compares every other input)
- audio focus machine (`src/audio_focus.rs`): what a call, a voice prompt, a navigation cue, unplugged headphones or the listener's own transport does to playback, as a pure step from (state, event, context) to the next state and the commands the player carries out. `test/core/services/audio_focus_machine_test.dart` compares it with the Dart machine on all 1 920 inputs
- stream recovery (`src/stream_recovery.rs`): the quick reconnect budget and its refill after healthy playback, whether a source that went away ended or was lost (a Linux stream that libmpv gives up on reports its end well short of its length, #905), and when the buffering watchdog arms and fails. `test/core/services/stream_recovery_rules_test.dart` compares it with Dart
- cross-server merging (`src/track_unifier.rs`): one library row per song found on several servers, by the same conservative score as Dart (title, album and artist overlap, a two-second length veto, conflicting track numbers), with text read by the search tokenizer so songs tagged in any script merge (#877). `test/core/catalog/track_unifier_native_test.dart` compares both on generated catalogs; `test/benchmarks/track_unifier_bench.dart` measures it (200 000 copies: ~2.4 s in Dart, ~0.5 s in Rust)
- the Songs list's order (`src/song_sort.rs`): title, artist, album and date added, each way, with its A–Z sections and the album every song is filed under. Every distinct string is ranked once, so the sort compares integers. `test/features/library/song_sort_native_test.dart` compares it with Dart on every order; `test/benchmarks/song_sort_bench.dart` measures it (200 000 songs by artist: ~750 ms in Dart, ~310 ms in Rust)

## How Flutter uses it

The crate is built into the app by a Dart build hook, with no download and no prebuilt binary:

- `hook/build.dart` (repo root) runs `cargo build --release --locked --offline` for the target being built and bundles `liblinthra_core.so` as a code asset. `flutter run`, `flutter build` and `flutter test` all run it.
- `src/ffi.rs` is the C ABI, with the eviction calls in `src/ffi/cache_eviction.rs`, the grouping call in `src/ffi/library_grouping.rs` the download rules in `src/ffi/downloads.rs` the queue in `src/ffi/queue.rs` the end-of-track rule in `src/ffi/track_end.rs`, the search order in `src/ffi/search_rank.rs`, tag reading in `src/ffi/tags.rs` the playback rules in `src/ffi/playback_rules.rs` the audio focus machine in `src/ffi/audio_focus.rs` stream recovery in `src/ffi/stream_recovery.rs` cross-server merging in `src/ffi/track_unifier.rs` and the Songs order in `src/ffi/song_sort.rs`. `lib/core/native/linthra_core_ffi.dart` declares the same functions with `@Native`. Change them together and bump `ABI_VERSION` in `ffi.rs` and `LinthraCore.abiVersion` in `lib/core/native/linthra_core.dart`.
- `lib/core/native/linthra_core.dart` is what the rest of the app uses: `LinthraCore.isAvailable` and `NativeSearchIndex`. `CacheEvictionPolicy` calls `lib/core/native/native_cache_eviction.dart` itself, and `groupAlbums` / `groupArtists` / `groupLibrary` call `lib/core/native/native_library_grouping.dart`, and `downloadGate` / `settleCanceled` / `heldAction` call `lib/core/native/native_downloads.dart`, and `PlaybackQueue` calls `lib/core/native/native_queue.dart`, so their callers need not know which path ran.

The Rust core is **optional for now**. When `cargo`/`rustc` are missing, a Linux build has no `cc` to link with, or the Rust standard library for the target isn't installed, the hook skips the library and `LinthraCore.isAvailable` is false, so every caller has to keep a Dart fallback. A cargo build that starts and fails does fail the app build.

| Target | What the hook needs |
| --- | --- |
| Linux (x64, arm64) | `cargo`, `rustc` and a C linker (`cc`) |
| Android | the same, plus `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`; the hook links with the NDK's clang |

`cargo` is found on `PATH`, then in `$CARGO_HOME/bin` and `~/.cargo/bin`. CI runs `flutter test` with `LINTHRA_REQUIRE_RUST=1`, which turns a skipped library into a failing test (`test/core/native/linthra_core_test.dart`).

The Flatpak builds it through the `org.freedesktop.Sdk.Extension.rust-stable` SDK extension (`flatpak/flatpak-flutter.yml`).

The Android builds (GitHub, Google Play, Sponsor, and the CI debug APK) install the Rust pinned in `.rust-version` with the Android targets (`.github/actions/setup-rust-android`), and `scripts/check_apk_rust_core.py` fails a build whose APK lacks the library for an ABI.

Not covered yet: F-Droid. Its recipe lives in fdroiddata and has to install the same `.rust-version` before the first release built this way, or its build stops matching the signed APK it is checked against. The change is in [docs/distribution/f-droid/rust.md](../../docs/distribution/f-droid/rust.md).

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

Folding is **not** fuzzy matching. It removes accents; it does not make near-misses match.

## Typos

A query word that starts no token anywhere in the catalog is matched instead against tokens a few typos away (`src/typos.rs`), so `motorhed`, `bjrok` and `metalica` find Motörhead, Björk and Metallica. A word that starts some token is never matched this way, so every search that found something before finds exactly the same tracks.

- Under 4 characters: no typo. 4 to 6: one. 7 and more: two.
- The first character must match.
- A typo is one character inserted, deleted or replaced, or two neighbours swapped.
- The word may be a mistyped start of the token (`metalic` while typing `metallica`).
- A match with typos scores half its field's weight, below any exact match of the same field.

## Good contribution areas

Rust contributors can work here without knowing Flutter. Useful next steps include compact index serialization, incremental index updates, cross-provider duplicate candidates, per-album and per-artist track lookups, memory benchmarks, and the eventual stable Dart/Flutter FFI boundary.
