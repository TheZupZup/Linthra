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

The crate is intentionally **not wired into Flutter yet**. The core is being benchmarked and stabilized behind a small API first; the later FFI binding can then be reviewed independently without mixing Android packaging risk into the indexing algorithm.

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
