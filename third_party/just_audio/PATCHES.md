# Vendored `just_audio`

Linthra vendors just_audio for its Android player only. Upstream builds its
ExoPlayer with fixed defaults and never looks at which tracks ExoPlayer could
actually decode, and both of those caused #674: on an Android 7 device with no
FLAC decoder, a FLAC track "played" in complete silence, with the session
reporting PLAYING, the position advancing and no error anywhere. Everything
here is upstream source except the hunks in [`upstream.patch`](upstream.patch):
three in `android/.../AudioPlayer.java`, plus a tooling-only exclusion in
`analysis_options.yaml`.

## Provenance

| | |
| --- | --- |
| Package | [`just_audio`](https://pub.dev/packages/just_audio) |
| Version | 0.9.46 |
| Upstream archive | `https://pub.dev/api/archives/just_audio-0.9.46.tar.gz` |
| Archive SHA-256 | `f978d5b4ccea08f267dae0232ec5405c1b05d3f3cd63f82097ea46c015d5c09e` |
| Upstream repository | <https://github.com/ryanheise/just_audio> |
| License | MIT, with the Apache-2.0 notice for the ExoPlayer it bundles (`LICENSE`, unmodified) |
| Android engine | Media3 ExoPlayer 1.4.1 (`android/build.gradle`, unmodified) |

The archive digest is the same `sha256` `pubspec.lock` recorded for the hosted
dependency before it was vendored, so the swap is verifiable against the
lockfile history rather than on trust.

### What is vendored

Every file pub ships in the package archive **except `example/`**, the same
rule as `third_party/just_audio_media_kit`. `upstream.sha256` lists each
vendored file with its **pristine upstream** digest; `pubspec.lock` is
Linthra's own addition, so the standalone analysis of this package resolves
deterministically.

The Dart API, the platform interface, iOS/macOS (`darwin/`) and the web
implementation are untouched. Linux keeps using `just_audio_media_kit`.

## The patch

Three changes to `android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java`.

**1. Extension renderers after the platform ones.** The player is built with a
`DefaultRenderersFactory` in `EXTENSION_RENDERER_MODE_ON` instead of the
default (`OFF`). Media3 then appends any extension renderer the app bundles
*after* its platform `MediaCodec` renderer, and the track selector only moves
past a renderer that does not fully handle a format. Linthra bundles one:
Media3's FLAC renderer
([`third_party/media3_decoder_flac`](../media3_decoder_flac/PATCHES.md)). So:

- a device whose platform decodes FLAC keeps using that decoder, exactly as
  before (no extra CPU, no behaviour change);
- a device without one (Android only guarantees FLAC from API 27; Linthra
  supports API 24) decodes FLAC with libFLAC instead of dropping the audio.

`PREFER` mode, which would put libFLAC first on every device, is deliberately
not used. With no extension bundled, `ON` builds exactly the renderers the
default factory does.

**2. Undecodable audio is an error, not silent playback.** When ExoPlayer has
a source with audio tracks but none of them selected (no renderer can decode
them, the #674 condition), Media3 does not fail. It drops the track, reaches
READY and advances position on a wall-clock timer with no `AudioTrack`, so the
app sees ordinary playback. `onTracksChanged` now detects exactly that, from
ExoPlayer's own track-selection result (`Tracks.containsType(AUDIO) &&
!Tracks.isTypeSelected(AUDIO)`, which includes groups no renderer took), not
from a timer. It then:

- fails the pending `load()` (or, mid-playback, the event stream) with code
  `4005`, Media3's `ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`, and a message
  naming only the sample MIME type (e.g. `audio/flac`, never the URI, which
  can carry credentials);
- stops the player so it cannot keep advancing;
- ignores the READY that may already be queued behind the error, so the
  failed source is never reported as loaded. `load()` clears the flag for
  the next source.

Linthra's controller classifies code 4005 as "this track's format isn't
supported on this device" (`classifyEngineError`), which offers another copy
of the song where one exists and never retries the same bytes.

**3. One logcat line per audio decoder.** An `AnalyticsListener` logs
`Audio decoder: <name>` when ExoPlayer initialises an audio decoder (a platform
codec name, or `libflac` for the fallback), so an `adb logcat` from a field
report shows which path actually played. Decoder names only; nothing about the
media or its location.

**4. `analysis_options.yaml` excludes `build/**` and `android/**`.** This is
exactly the rewrite Flutter 3.47's `flutter pub get` applies to a plugin package
on its own. It is recorded here so the provenance check stays stable when the
analysis step has run `pub get` in this directory. It changes what the analyzer
looks at, nothing that is compiled.

Nothing else changes: no new dependency in this package, no new permission,
no network or file access, no change to audio focus, audio attributes,
buffering, or the method and event channel protocol (the error travels on the
existing `sendError` path, like every ExoPlayer error).

## Auditing this directory

`./scripts/check_vendored_packages.sh` reverse-applies `upstream.patch` onto a
copy of this tree and checks the result against `upstream.sha256`, offline,
then analyzes the package with the pinned Flutter toolchain. CI runs it on
every PR.

## Refreshing against a new upstream version

1. Download the new archive and verify its `sha256` against pub.dev.
2. Replace every file listed in `upstream.sha256` with the new upstream copy and
   regenerate that manifest from the pristine tree.
3. Re-apply the three hunks and regenerate `upstream.patch`.
4. **If the Media3 version in `android/build.gradle` changed**, update
   `third_party/media3_decoder_flac` to the same Media3 release. A decoder
   module from another release is unsupported.
   `test/tooling/media3_flac_fallback_build_test.dart` fails until they match.
5. Update the tables above, refresh `pubspec.lock`, and run
   `./scripts/check_vendored_packages.sh`.
6. If upstream ever exposes a renderers factory or reports unsupported tracks
   itself, move to that and drop the matching hunk.
