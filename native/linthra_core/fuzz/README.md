# Fuzzing the file parsers

The tag readers (`src/tags/`) and the CUE sheet parser (`src/cue_sheet.rs`)
read files from NAS shares, USB drives and bad rips, and the Subsonic reader
(`src/subsonic/`) reads whatever a server, or a proxy in front of it, sends.
These targets throw
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
| `subsonic_response` | a server's answer: the envelope, then every list read out of it |

## Running

cargo-fuzz needs nightly. `rust-toolchain.toml` here pins the date, so from
this folder cargo picks it up on its own:

```bash
cargo install cargo-fuzz --version 0.13.2 --locked
```

From `native/linthra_core/fuzz/`, seed the corpora from the test fixtures,
then run a target for a while:

```bash
./seed.sh
cargo fuzz run -O tags_mp4 -- -max_total_time=300 -max_len=65536
```

A panic leaves the input under `artifacts/<target>/`. Replay it with
`cargo fuzz run -O <target> <file>`, turn it into a test next to the
reader it broke, and fix the reader. `corpus/` and `artifacts/` are not
committed; `seeds/` holds the inputs `seed.sh` can't take from
`test/fixtures/`.

## In CI

`.github/workflows/rust-fuzz.yml` runs every target for 10 minutes each
Sunday, and for a minute on a pull request that touches the parsers or the
targets. A panic fails the run and keeps the input as an artifact
(`fuzz-crash-<target>`). Moving the nightly pin is a change of its own:
bump the date in `rust-toolchain.toml` and let the pull request's short run
check it builds.
