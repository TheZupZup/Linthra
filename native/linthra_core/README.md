# linthra_core (Rust)

`linthra_core` is Linthra's high-performance library engine. Its first job is to make searching very large catalogs predictable without making Flutter walk 100,000–200,000 track objects for every keystroke.

## Current scope

- dependency-free Rust core
- immutable inverted index
- title / artist / album / album-artist / provider tokens
- accent-folded, case-folded tokens, so `bjork` finds `Björk`
- prefix search with AND semantics across query terms
- deterministic ranking
- synthetic 200,000-track regression benchmark

## How Flutter uses it

The crate is built into the app by a Dart build hook, with no download and no prebuilt binary:

- `hook/build.dart` (repo root) runs `cargo build --release --locked --offline` for the target being built and bundles `liblinthra_core.so` as a code asset. `flutter run`, `flutter build` and `flutter test` all run it.
- `src/ffi.rs` is the C ABI. `lib/core/native/linthra_core_ffi.dart` declares the same functions with `@Native`. Change them together and bump `ABI_VERSION` in `ffi.rs` and `LinthraCore.abiVersion` in `lib/core/native/linthra_core.dart`.
- `lib/core/native/linthra_core.dart` is what the rest of the app uses: `LinthraCore.isAvailable` and `NativeSearchIndex`.

The Rust core is **optional for now**. When `cargo`/`rustc` are missing, a Linux build has no `cc` to link with, or the Rust standard library for the target isn't installed, the hook skips the library and `LinthraCore.isAvailable` is false, so every caller has to keep a Dart fallback. A cargo build that starts and fails does fail the app build.

| Target | What the hook needs |
| --- | --- |
| Linux (x64, arm64) | `cargo`, `rustc` and a C linker (`cc`) |
| Android | the same, plus `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`; the hook links with the NDK's clang |

`cargo` is found on `PATH`, then in `$CARGO_HOME/bin` and `~/.cargo/bin`. CI runs `flutter test` with `LINTHRA_REQUIRE_RUST=1`, which turns a skipped library into a failing test (`test/core/native/linthra_core_test.dart`).

Not covered yet: the Flatpak (it needs the `rust-stable` SDK extension) and F-Droid (its recipe needs Rust). Both currently ship without the Rust core and use the Dart fallback.

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

Rust contributors can work here without knowing Flutter. Useful next steps include compact index serialization, incremental index updates, cross-provider duplicate candidates, album grouping primitives, memory benchmarks, and the eventual stable Dart/Flutter FFI boundary.
