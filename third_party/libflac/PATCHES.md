# Vendored libFLAC (decoder subset)

Linthra vendors the **decoding half** of libFLAC so Android devices without a
platform FLAC decoder can still play FLAC. Everything here is unmodified
upstream source. There is no patch.

It is compiled only by the Android build, through
[`third_party/media3_decoder_flac`](../media3_decoder_flac/PATCHES.md), into
`libflacJNI.so`. Linux playback never loads it.

## Why it exists

Linthra plays audio on Android through just_audio, which uses Media3
ExoPlayer. ExoPlayer's own FLAC extractor hands FLAC frames to a platform
`MediaCodec` decoder, and Android only guarantees one from API 27 (Android
8.1). Linthra supports API 24. On API 24 to 26 devices that ship no vendor FLAC
decoder (#674: an Echo Show 8 on Fire OS), ExoPlayer used to silently drop the
audio track and "play" nothing.

With this library in the build, Media3's `LibflacAudioRenderer` decodes FLAC in
the app **only when the platform decoder cannot**. Devices with a platform FLAC
decoder keep using it. See `third_party/just_audio/PATCHES.md` for how that
order is enforced.

## Provenance

| | |
| --- | --- |
| Project | libFLAC, part of [FLAC](https://xiph.org/flac/) (Xiph.Org Foundation) |
| Version | 1.5.0 (released 2025-02-11, the latest upstream release) |
| Upstream repository | <https://github.com/xiph/flac> |
| Tag | `1.5.0` |
| Commit | `1507800de4b70e21be71f38caa0d9079d0bc6e45` |
| License | BSD-3-Clause (`COPYING.Xiph`, unmodified) |

Every file was taken from the commit above, not from a moving branch.
`upstream.sha256` records each file's digest, so the claim "unmodified
upstream" is checked offline by `scripts/check_vendored_packages.sh` on every
PR.

## What is vendored, and what is not

Only what the stream **decoder** needs. The set is exactly the link closure of
`FLAC__stream_decoder_*` (the only libFLAC API Media3's JNI glue calls), checked
by linking with `--no-undefined`:

- `src/libFLAC/`: `bitmath.c`, `bitreader.c`, `cpu.c`, `crc.c`, `fixed.c`,
  `format.c`, `lpc.c`, `md5.c`, `memory.c`, `stream_decoder.c`, plus the two
  `deduplication/*.c` fragments those files `#include`.
- The headers those sources include (`include/FLAC`, `include/share`,
  `src/libFLAC/include`).
- `COPYING.Xiph`, `AUTHORS`, `README.md`.

Not vendored: the encoder, metadata editing (`metadata_*.c`), Ogg support,
libFLAC++, the command-line tools, tests, docs, and the SSE/AVX/NEON intrinsic
files. Leaving out the encoder and metadata writers keeps
[CVE-2020-22219](https://nvd.nist.gov/vuln/detail/CVE-2020-22219) and
[CVE-2021-0561](https://nvd.nist.gov/vuln/detail/CVE-2021-0561)-class code
(both encoder-side, both already fixed upstream) out of the binary entirely.

## How it is built

Not with libFLAC's own CMake. `media3_decoder_flac/src/main/jni/CMakeLists.txt`
compiles the files above directly, with a fixed set of definitions instead of a
generated `config.h`:

- `FLAC__NO_ASM`, `FLAC__HAS_*INTRIN=0`: portable C only, with no runtime CPU
  feature dispatch. The same code runs on armeabi-v7a, arm64-v8a and x86_64.
  FLAC decoding is cheap enough that the intrinsics buy nothing for playback.
- `FLAC__HAS_OGG=0`: no Ogg FLAC in libFLAC. Media3's own Ogg extractor
  already unwraps Ogg FLAC before it reaches the decoder.
- `ENABLE_64_BIT_WORDS=0`: 32-bit bit-reader words on every ABI, which is
  upstream's default.
- Hardening flags (`-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, hidden
  visibility, full RELRO, no undefined symbols).

## Security

Audio files are untrusted input, and this is the code that parses them when the
fallback is in use.

- libFLAC has been continuously fuzzed by
  [OSS-Fuzz](https://github.com/google/oss-fuzz/tree/master/projects/flac) with
  ASan, UBSan and MSan for years, and 1.5.0 improved fuzzing again.
- Every published libFLAC CVE is fixed at or before this version. The most
  recent decoder one, [CVE-2020-0499](https://nvd.nist.gov/vuln/detail/CVE-2020-0499)
  (an out-of-bounds read in the bit reader), was fixed in 1.3.4. Media3's own
  README still names flac 1.3.2, which predates that fix, so Linthra
  deliberately does not follow it.
- Upstream has no published GitHub security advisories.
- The code only runs for FLAC tracks on devices whose platform cannot decode
  them. Everywhere else it is loaded (Media3 checks that the library is
  present) but never handed a byte of audio.

## Refreshing against a new upstream release

1. Pick the new release tag and note its commit.
2. Replace every file listed in `upstream.sha256` from that commit and
   regenerate the manifest from the pristine files.
3. Rebuild the link-closure check: compile the listed `.c` files with the
   definitions in `media3_decoder_flac/src/main/jni/CMakeLists.txt` and link
   with `-Wl,--no-undefined`. Add or drop files until it links, and update
   the source list in that CMake file to match.
4. Update the tables above and run `./scripts/check_vendored_packages.sh`.
