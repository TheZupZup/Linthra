# Fuzzing the file parsers

The tag readers (`src/tags/`) and the CUE sheet parser (`src/cue_sheet.rs`)
read files from NAS shares, USB drives and bad rips. These targets throw
mutated files at them and look for panics. A panic doesn't crash the app (the
C ABI catches it, see `guard` in `src/ffi.rs`), but the file then reads as
unreadable, so every one found is a bug to fix, with a regression test.

| Target | Reads |
| --- | --- |
| `tags_flac`, `tags_ogg`, `tags_mp3`, `tags_mp4`, `tags_wav`, `tags_aiff`, `tags_ape` | one format's reader, from the start of the file |
| `tags_any` | `tags::read`, which picks the reader by the file's magic |
| `tags_id3v2` | an ID3v2 body (first two bytes: version, flags) |
| `tags_vorbis_comments` | a Vorbis comment block |
| `tags_picture` | a FLAC picture block |
| `cue_sheet` | a sheet's bytes, decoded and parsed |

## Running

cargo-fuzz needs a nightly toolchain:

```bash
rustup toolchain install nightly --profile minimal
cargo install cargo-fuzz --locked
```

From `native/linthra_core/`, seed the corpora from the test fixtures, then
run a target for a while:

```bash
./fuzz/seed.sh
cargo +nightly fuzz run -O tags_mp4 -- -max_total_time=300 -max_len=65536
```

A panic leaves the input under `fuzz/artifacts/<target>/`. Replay it with
`cargo +nightly fuzz run -O <target> <file>`, turn it into a test next to the
reader it broke, and fix the reader. `corpus/` and `artifacts/` are not
committed; `seeds/` holds the inputs `seed.sh` can't take from
`test/fixtures/`.
