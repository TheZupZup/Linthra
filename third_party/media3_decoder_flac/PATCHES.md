# Vendored Media3 FLAC decoder module

Linthra vendors Media3's `decoder_flac` library module so Android can play FLAC
on devices whose platform has no FLAC decoder. Google does **not** publish this
module to Maven: upstream only supports building it from source, so vendoring
it is the only way to ship it, and building from source is also what F-Droid
needs.

## The problem it solves (#674)

Linthra plays audio on Android through just_audio, which uses Media3 ExoPlayer.
ExoPlayer's FLAC extractor hands FLAC frames to a platform `MediaCodec`
decoder. Android only guarantees one from API 27; Linthra supports API 24. When
a device has none (the Echo Show 8 on Fire OS in #674), ExoPlayer's track
selector drops the audio track, the player still reaches READY and runs on a
wall-clock timer, and nothing ever creates an `AudioTrack`: silent "playback"
with no error.

This module adds `LibflacAudioRenderer`, a software FLAC decoder built on the
vendored [libFLAC 1.5.0](../libflac/PATCHES.md). just_audio's player turns on
Media3's extension renderers (see
[`third_party/just_audio/PATCHES.md`](../just_audio/PATCHES.md)), which places
this renderer **after** the platform `MediaCodec` renderer:

- Platform decoder handles the FLAC stream: it is used, exactly as before.
- No platform decoder, or one that cannot take this stream: this renderer
  decodes it.
- Neither can: the patched just_audio reports an unsupported-format error
  instead of pretending to play.

## Provenance

| | |
| --- | --- |
| Project | [AndroidX Media](https://github.com/androidx/media) (Media3), module `libraries/decoder_flac` |
| Version | 1.4.1, the Media3 release just_audio 0.9.46 depends on |
| Tag | `1.4.1` |
| Commit | `c35a9d62baec57118ea898e271ac66819399649b` |
| License | Apache-2.0 (`LICENSE`, the repository's, unmodified) |

`upstream.sha256` records the pristine digest of every upstream file here;
`scripts/check_vendored_packages.sh` checks it offline on every PR.

Media3 1.4.1's JNI glue is semantically identical to current upstream's, which
builds it against libFLAC's development branch. Pairing it with libFLAC 1.5.0
is therefore what upstream itself does today, not a Linthra combination. (The
1.4.1 README's flac 1.3.2 predates the fix for CVE-2020-0499 and is
deliberately not followed.)

## What is vendored

Unmodified upstream files:

- `src/main/java/androidx/media3/decoder/flac/`: `FlacDecoder`,
  `FlacDecoderException`, `FlacDecoderJni`, `FlacLibrary`,
  `LibflacAudioRenderer`, `package-info`.
- `src/main/jni/`: `flac_jni.cc`, `flac_parser.cc`, `include/*.h` (the JNI
  wrapper around libFLAC's stream decoder).
- `proguard-rules.txt` (upstream's consumer rules for the JNI callbacks).
- `LICENSE`.

**Deliberately not vendored:** the module's `FlacExtractor` and
`FlacBinarySearchSeeker`. When that class is present, Media3's
`DefaultExtractorsFactory` switches *every* device to it, and it decodes FLAC
in the extractor, bypassing the platform decoder even where one exists. Without
it, Media3 keeps its core `FlacExtractor`, which leaves decoding to the renderer
chosen per device. That is what keeps modern devices on their platform decoder.
(`FlacLibrary`'s javadoc still `@link`s the missing class; javadoc links are not
compiled.)

Linthra's own files, listed in `local.files`:

- `build.gradle`: builds the sources against the published
  `androidx.media3:media3-exoplayer:1.4.1` (upstream's build uses Media3's
  monorepo config). SDK levels and NDK come from `:app`, so they track the
  versions Flutter pins.
- `src/main/AndroidManifest.xml`: empty. Upstream's uses the `package`
  attribute, which AGP 8 rejects.
- `src/main/jni/CMakeLists.txt`: compiles the JNI glue and the vendored
  libFLAC decoder subset into `libflacJNI.so`, with hardening flags
  (`-fwrapv`, stack protector, hidden visibility, full RELRO,
  `--no-undefined`, 16 KB page alignment) and `-ffile-prefix-map`, so no
  checkout path ends up in the library (F-Droid's reproducible-build check
  compares it byte for byte).
- `linthra-consumer-rules.pro`: keeps the classes Media3 finds by reflection,
  so R8 cannot remove the fallback.

## ABIs

`armeabi-v7a`, `arm64-v8a` and `x86_64`: every ABI Linthra ships, and the
three Flutter ships `libflutter.so` for. The library is portable C/C++ with no
assembly or intrinsics, so it builds the same on all three.

## Security

Audio files are untrusted input. What this module adds to the attack surface,
and when:

- **Only for FLAC the platform cannot decode.** On a device with a platform
  FLAC decoder, the platform decoder is chosen and this code never sees a
  byte of audio. `libflacJNI.so` is still loaded there, because Media3 asks
  whether it is available.
- The parser is libFLAC (continuously fuzzed on OSS-Fuzz) behind Media3's JNI
  wrapper, which rejects blocks that break STREAMINFO's promises (block size,
  sample rate, channels, bit depth) and checks the output buffer size before
  every copy.
- No network, file or process access of its own: it decodes bytes Media3
  already read.
- Linthra validated the exact build in this directory on a Linux host under
  ASan and UBSan: bit-exact decoding of 8/16/24-bit, 22.05–192 kHz,
  mono/stereo/5.1 streams, then 20,000 mutated inputs per stream (bit flips,
  truncation, STREAMINFO corruption, garbage, splices) with no memory error or
  undefined behaviour. That run found the one libFLAC behaviour `-fwrapv`
  exists for: signed overflow on crafted residuals, which upstream considers
  benign and now wraps by definition.

## Refreshing

1. Bump only together with the Media3 version just_audio uses (see
   `third_party/just_audio/PATCHES.md`). A mismatched decoder module is
   unsupported by Media3. `test/tooling/media3_flac_fallback_build_test.dart`
   fails the build when the two drift.
2. Copy the listed upstream files from the new tag, regenerate
   `upstream.sha256`, and review the diff of the JNI glue.
3. Check `FlacExtractor` is still the only class that would switch the
   extractor, and still leave it out.
4. Run `./scripts/check_vendored_packages.sh`.
