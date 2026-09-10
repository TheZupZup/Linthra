# Vendored `just_audio_media_kit`

Linthra vendors this package for one reason: upstream keeps libmpv entirely to
itself. It has no public hook for setting extra options at player creation, and
no way at all to reach the `Player` it built — and Linthra needs both, on three
paths: production playback, the headless audio smoke test, and Linux audio
output device selection. Everything here is upstream source except the hunks in
[`upstream.patch`](upstream.patch).

## Provenance

| | |
| --- | --- |
| Package | [`just_audio_media_kit`](https://pub.dev/packages/just_audio_media_kit) |
| Version | 2.1.0 |
| Upstream archive | `https://pub.dev/api/archives/just_audio_media_kit-2.1.0.tar.gz` |
| Archive SHA-256 | `f3cf04c3a50339709e87e90b4e841eef4364ab4be2bdbac0c54cc48679f84d23` |
| Upstream repository | <https://github.com/Pato05/just_audio_media_kit> |
| License | MIT (`LICENSE`, unmodified) |

The archive digest is the same `sha256` `pubspec.lock` recorded for the hosted
dependency before it was vendored, so the swap is verifiable against the
lockfile history rather than on trust.

### What is vendored

Every file pub ships in the package archive **except `example/`** (a full
sample Flutter app: not compiled, not analyzed, and not part of the dependency).
`upstream.sha256` lists each vendored file with its **pristine upstream**
digest; `pubspec.lock` is Linthra's own addition, so the standalone analysis of
this package resolves deterministically.

## The patch

Two additions, in two files, no deletions.

**1. `mpvProperties` — extra libmpv options at player creation.**

- `lib/just_audio_media_kit.dart` adds `JustAudioMediaKit.mpvProperties`, an
  optional `Map<String, String>` that defaults to empty.
- `lib/mediakit_player.dart` applies each entry with the package's existing
  `setProperty` helper right after `Player()` construction, next to the
  identical `prefetch-playlist` call upstream already makes.

**2. `livePlayers` — a registry of the players that currently exist.**

- `lib/just_audio_media_kit.dart` adds `JustAudioMediaKit.livePlayers`, a
  `Map<String, Player>` keyed by the just_audio player id.
- `lib/mediakit_player.dart` adds its player to that map right after
  construction and removes it in `release()`, so the map only ever holds
  players that are alive.

Nothing else changes: no new dependency, no new I/O, no new process or library
loading, and no call into libmpv that upstream does not already make. With the
map left empty and the registry unread, the generated libmpv calls are
byte-for-byte what upstream makes; Linthra does not leave them unused (see
below), so the difference from upstream is exactly what it does with them.

### Why

**`mpvProperties`.** Headless Linux CI has no PipeWire/Pulse device, and
libmpv autoselects PipeWire on Ubuntu, so the native audio lifecycle smoke test
needs its own `ao` set on each libmpv instance before playback starts (it uses
libmpv's `null` output, which discards the samples but still paces them against
the system clock). Production needs the same hook for `cache-on-disk=no`.
Upstream exposes `setProperty` internally but has no public hook for extra mpv
options at player creation (unlike `prefetchPlaylist`).

**`livePlayers`.** just_audio's platform interface has no concept of an audio
*output device*: nothing in `AudioPlayerPlatform` lists the sinks the host
offers or moves playback onto one. libmpv models both (`audio-device-list` and
`audio-device`), and media_kit exposes both on `Player` — but that `Player` is
private to `MediaKitPlayer`, so there is no way to reach it from the app. The
registry is the smallest thing that fixes that: the app looks up the live
player, reads the device list from it, and calls media_kit's own
`setAudioDevice` on it, so audio that is *already playing* moves to the chosen
output ([#402](https://github.com/thezupzup/linthra/issues/402)).

### Who sets `mpvProperties`

**Three callers, and two of them are production.** This hook is *not* CI-only —
removing it breaks shipped playback behaviour, not just a test.

| Caller | Sets | Why |
| --- | --- | --- |
| `lib/core/services/linux_playback_controller.dart` (`linuxMpvProperties`) | `cache-on-disk=no` | media_kit turns mpv's on-disk demuxer cache on for every player; Linthra streams audio and manages its own offline cache, and mpv logs `[lavf] Failed to create file cache.` on every stream where it cannot write the temporary file ([#405](https://github.com/thezupzup/linthra/issues/405)). |
| `tool/linux_audio_backend_smoke.dart` | `ao=null` (overridable) | The headless CI case described above. |
| `lib/core/services/linux_audio_output_device_service.dart` | `audio-device=<chosen device>` | The user's chosen audio output, so a player created *after* the choice starts on it. Only set once the listener picks a device; never written on a default install. |

The smoke target layers its value on top of the production defaults rather than
replacing them (`resolveLinuxMpvProperties` merges), so CI exercises the same
cache configuration production uses, with only the output device swapped. The
output-device service merges too, for the same reason: an output change must not
drop `cache-on-disk=no`.

### Who reads `livePlayers`

One caller: `lib/core/services/linux_audio_output_device_service.dart`. It reads
a live player to enumerate `audio-device-list` and calls `setAudioDevice` on
every entry when the listener picks an output. When the map is empty (nothing is
playing) it builds its own short-lived `Player` for enumeration instead and
disposes it, so the registry is never a requirement for listing outputs — only
for moving audio that is already playing.

## Auditing this directory

`./scripts/check_vendored_packages.sh` verifies the whole claim above **offline**
(no downloads): it reverse-applies `upstream.patch` onto a copy of the vendored
tree and checks the result against `upstream.sha256`. If the recorded hunks are
the only local change, the restored files hash to upstream's; any other edit —
or a patch that no longer describes the tree — fails the check.

The same script analyzes the package from its own directory with the
repository's pinned Flutter toolchain, because the root `analysis_options.yaml`
excludes `third_party/**` (upstream code is not held to Linthra's stricter lint
set). CI runs it on every PR.

### Refreshing against a new upstream version

1. Download the new archive and verify its `sha256` against pub.dev.
2. Replace every file listed in `upstream.sha256` with the new upstream copy and
   regenerate that manifest from the pristine tree.
3. Re-apply the hunks (`git apply upstream.patch`, or by hand if they moved) and
   regenerate `upstream.patch` from the pristine-vs-vendored diff. **Do not drop
   them because upstream gained something similar** without checking every
   caller in *Who sets `mpvProperties`* and *Who reads `livePlayers`* first:
   shipped playback and output-device selection both depend on these, so losing
   one is a silent behaviour change, not a test-only regression.
4. Update the tables above, refresh `pubspec.lock`, and run
   `./scripts/check_vendored_packages.sh`.
5. If upstream ever adds its own public hooks — player-creation properties, or
   any access to the underlying `Player` — move the callers onto them and drop
   the matching hunk. That is the outcome this vendoring exists to make
   unnecessary.
