# Linux desktop

Linthra has a native Flutter Linux target. This page is how to build and run it,
what works today, and what deliberately does not yet.

> **Linux is not production-ready.** This is the second milestone of
> [issue #376](https://github.com/TheZupZup/Linthra/issues/376): the app
> compiles, launches, renders in a real desktop window, and plays local and
> server audio. Desktop media controls and packaging are later milestones.
> Android is unaffected and remains the platform Linthra actually ships on.

## What exists after this milestone

* `linux/` is committed, like `android/`. No `flutter create` step.
* `flutter build linux` produces a runnable bundle.
* The window carries Linthra's real identity: application id
  `io.github.thezupzup.linthra` (the same reverse-DNS id as the Android build),
  window title `Linthra`, a 1180×780 default size and a 420×600 minimum.
* The window remembers its size, maximized state and (on X11) its position
  across restarts — see [Window state](#window-state).
* Every shared layer is the same code Android runs: domain models, providers,
  repositories, routing, theming, the local scanner, and the Jellyfin /
  Navidrome / Subsonic / Plex integrations.
* Server credentials persist in **encrypted** storage on Linux, through the
  desktop Secret Service (see [Secure storage](#secure-storage)).
* CI builds the Linux target on every PR
  ([`linux-desktop-build.yml`](../.github/workflows/linux-desktop-build.yml)).
  For an official release, that same workflow is separately dispatched to
  build at the exact release tag, package the bundle into a `.tar.gz`, and
  attach it to the GitHub Release — see [Release tarball](#release-tarball)
  below and
  [docs/release-process.md §4a](./release-process.md#4a-linux-release-tarball-dispatched-alongside-the-android-build).
* A stable Release also carries an installable `.flatpak` bundle, built by
  [`flatpak-build.yml`](../.github/workflows/flatpak-build.yml) at the same tag
  — see
  [Installing from GitHub Releases](#installing-from-github-releases-flatpak).

## Required packages

The Flutter Linux toolchain plus the native libraries Linthra's plugins need,
for the **native** build described on this page.

> Building the **Flatpak** instead? None of these packages are needed for it —
> it brings its own toolchain and bundles its own libmpv. See
> [flatpak-development.md](./flatpak-development.md).

### Fedora / Fedora Kinoite

```bash
sudo dnf install \
  clang cmake ninja-build pkgconf-pkg-config \
  gtk3-devel xz-devel libsecret-devel mpv-libs mpv-devel
```

On **Kinoite** (and any rpm-ostree system) do development work inside a
toolbox rather than layering packages onto the host image:

```bash
toolbox create linthra
toolbox enter linthra
# then run the dnf command above inside the toolbox
```

### Debian / Ubuntu

```bash
sudo apt install \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev libsecret-1-dev libmpv-dev
```

### Arch

```bash
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 xz libsecret mpv
```

### What each one is for

| Package | Needed by |
| --- | --- |
| `clang`, `cmake`, `ninja`, `pkg-config` | the Flutter Linux build itself |
| GTK 3 development headers | the Flutter Linux embedder |
| `liblzma` / `xz` development headers | Flutter tool prerequisite |
| **libsecret development headers** | `flutter_secure_storage_linux` — encrypted credential storage. Not optional: without it the plugin does not build, and Linthra never falls back to plaintext credentials. |
| **libmpv** | `just_audio_media_kit` / `media_kit` — local and HTTP(S) audio decoding, seeking, timing, and output through PulseAudio or PipeWire. Ubuntu's `libmpv-dev`, Fedora's `mpv-libs` + `mpv-devel`, and Arch's `mpv` provide it. |

At **runtime** the app additionally needs libmpv and wants a Secret Service provider
(`gnome-keyring` on GNOME, `kwallet` with its Secret Service interface on KDE).
Both are present on a standard Fedora Workstation or Kinoite install.

## Building and running from source

```bash
./scripts/setup_flutter.sh                       # the pinned Flutter (no sudo)
export PATH="$PWD/.tool/flutter/bin:$PATH"

flutter config --enable-linux-desktop
flutter pub get --enforce-lockfile
flutter run -d linux                             # or: flutter build linux --release
```

A release build lands in `build/linux/x64/release/bundle/`; run
`./build/linux/x64/release/bundle/linthra`.

To run the same checks CI runs:

```bash
./scripts/verify_linux.sh
```

That does `pub get --enforce-lockfile`, `dart format --set-exit-if-changed`,
`flutter analyze`, `flutter test`, the runner configuration check, the desktop
entry check (`desktop-file-validate` on
`linux/packaging/io.github.thezupzup.linthra.desktop`, skipped with a note if
`desktop-file-utils` is not installed), the same
native audio lifecycle smoke CI runs (builds and runs
`tool/linux_audio_backend_smoke.dart`), and `flutter build linux --release`.
It skips the smoke test and the build if the native packages above are
missing — including the libmpv *runtime* library, checked the same way
media_kit loads it, since a Linux build succeeds without libmpv but can't play
anything — and says which ones. `scripts/verify_android.sh` is unchanged and
still the Android twin.

### Building without a network

`sqlite3_flutter_libs` compiles SQLite into the app so the Drift catalog runs on
the same engine and the same compile flags Android uses. On Linux its CMake
downloads the SQLite amalgamation from `sqlite.org` while *configuring* the
build. That is fine on a normal machine and impossible in a sandboxed or
air-gapped build — including `flatpak-builder`, which builds with networking
disabled.

`linux/CMakeLists.txt` therefore honours `LINTHRA_SQLITE3_SOURCE_DIR`: point it
at an already-unpacked amalgamation (a directory containing `sqlite3.c`) and
nothing is downloaded.

```bash
LINTHRA_SQLITE3_SOURCE_DIR=/path/to/sqlite-autoconf-XXXXXXX \
  flutter build linux --release
```

It works through CMake's own `FETCHCONTENT_SOURCE_DIR_<NAME>` hook, so the
plugin is neither patched nor vendored — leave the variable unset and the build
is byte-for-byte the upstream one. `scripts/check_linux_runner.py` fails if the
seam is ever removed, because losing it breaks nothing on a machine with a
network and would only surface at packaging time.

## Secure storage

`flutter_secure_storage` publishes a real Linux implementation
(`flutter_secure_storage_linux`), and Linthra uses it unchanged. On Linux it
stores through **libsecret**, i.e. the freedesktop Secret Service — the same
place your other desktop apps keep credentials — instead of Android's Keystore.
Jellyfin, Subsonic/Navidrome and Plex sessions are encrypted at rest on Linux
exactly as they are on Android.

What is stored: one entry per provider (`jellyfin_session_v1`,
`subsonic_session_v1`, `plex_session_v1`), each the JSON of a session object.
Passwords are never among them: Jellyfin exchanges one for an access token,
Subsonic derives a salt+token pair and discards it, Plex is token-based from
the start.

Three runtime facts worth knowing:

* A Secret Service provider must be running and **unlocked**. On a normal
  desktop session the login keyring is unlocked at login and nothing is asked
  of you. On a bare window manager with no keyring daemon, or with the keyring
  locked, reads and writes fail.
* A failure is reported, not swallowed. The three provider stores go through
  one wrapper, `SecureSessionStorage`
  (`lib/data/repositories/secure_session_storage.dart`), which turns a platform
  failure into a typed `SecureStorageException` (unavailable, locked, denied,
  unknown) carrying nothing from the platform error, so a token cannot reach a
  log or a diagnostics report through it. The provider settings cards turn that
  into a recoverable message ("Couldn't save your Jellyfin sign-in on this
  device. Unlock your keyring and try again."), the app stays usable, and a
  session that could not be saved is not adopted: it would look signed in until
  the next launch and then be gone.
* Credential storage was not weakened to make Linux work, and Linthra has no
  plaintext fallback on any platform. A failed write stores nothing in
  preferences, the database, the cache, or any file Linthra writes.

In the **Flatpak** the same plugin reaches secure storage differently, and
without any D-Bus permission: libsecret detects the sandbox and, when the
desktop provides the xdg-desktop-portal Secret portal (GNOME via gnome-keyring,
KDE Plasma 6 via KWallet's `ksecretd`), keeps its own gcrypt-encrypted store
under the app's data directory with the master secret handed over by that
portal. Encrypted at rest either way, and libsecret's storage in both cases,
just not the shared keyring collection this page's native build uses. See
[flatpak-development.md](./flatpak-development.md#secure-credential-storage).

## Audio playback

Linux uses `just_audio_media_kit`, which implements the same `just_audio`
platform contract as Android's engine but delegates decoding and output to
media_kit/libmpv. This was chosen over a second, parallel playback stack because
Linthra's existing `JustAudioPlaybackController` already owns the difficult
parts: ordered playable candidates, offline-to-stream fallback, queue mutation,
shuffle/repeat, completion, retries, position/duration state, ReplayGain, and
safe errors. `LinuxPlaybackController` only registers the Linux implementation;
Android still constructs `JustAudioPlaybackController` and therefore remains on
ExoPlayer, `audio_service`, and its existing audio-focus behavior.

The same resolved URI path handles regular filesystem files and direct or
transcoded Jellyfin, Navidrome/Subsonic, and supported Plex HTTP(S) URLs. No
source-specific player exists and credentials remain in the existing resolver.

### When a track won't play

Desktop listening runs into more of this than a phone does: a NAS that is
asleep, an unmounted drive, a codec libmpv wasn't built with. So a track that
gives up says what happened and offers what can still be done about it, in
place. Now Playing shows the message where the source badge usually sits, with
Retry, "Try another source" and Skip as they apply, and the mini-player's second
line says the track is failing. Nothing is modal; the queue, the library and
settings keep working.

The model behind it (`PlaybackFailure`) and the controller actions
(`retryCurrentTrack`, `tryAnotherSource`) live on the shared playback seam, so
Android gets exactly the same behaviour from exactly the same code, and a source
switch reuses the existing logical-track candidates rather than a second
fallback path. The rules (which recoveries are valid for which failure, the
bounded attempt budget, what happens to the queue) are in
[streaming.md](streaming.md#when-a-track-cant-play-at-all).

### When the audio engine itself won't start

Linux is the only platform where the audio engine is somebody else's package.
Android ships its engine inside the app, so if the app runs, the engine is
there. On Linux, libmpv is loaded from the system at startup, and it can be
absent, unreadable, or the wrong build entirely. All three used to surface as
whatever generic per-track error the failure happened to reach, which told a
listener to check their network for a problem that was a missing package
([issue #404](https://github.com/TheZupZup/Linthra/issues/404)).

So the runtime is now a failure kind of its own,
`PlaybackFailureKind.playbackEngineUnavailable`, and it says what it is:

| What is wrong | What the player says |
| --- | --- |
| No usable libmpv on the system | Install or reinstall the distribution's libmpv package (`libmpv2` on Debian/Ubuntu, `mpv-libs` on Fedora, `mpv` on Arch) |
| libmpv is there and will not load | Reinstall the distribution's libmpv package |
| libmpv is there and does not match this build | Update it through the package manager |
| The backend would not start for some other reason | Check that libmpv is installed and working |

Each of those ends with the recovery that actually applies: "Then choose
Retry." when libmpv was never loaded, and "Then restart Linthra" when it was
(see the second bullet below for why the two differ).

Inside a Flatpak the wording changes, because a Flatpak bundles its own libmpv
and never loads the host's ([flatpak-development.md](./flatpak-development.md)):
the fix there is reinstalling Linthra from Flathub, and an `apt install` line
would send the listener to repair a library the app does not use.

Four decisions are worth knowing about:

* **It is the engine's failure, not the track's.** One engine plays everything,
  so "Try another source" and "Skip" are not offered: both would go through the
  same dead engine. Retry is the only button, and it is not subject to the
  bounded per-track attempt budget, because the recovery happens on the machine
  and taking the button away after three taps would leave a dead player with
  nothing to press.
* **Retry re-initializes, up to a point, and says which.** A libmpv that was
  never loaded is the recoverable case: `LinuxPlaybackBackendInitializer` marks
  itself ready only after registration returns, so every playback attempt that
  finds it unready tries again. Install the package, press Retry, and the music
  starts, with no restart of Linthra and certainly none of the machine.

  A libmpv that *did* load and then turned out to be the wrong one is not
  recoverable in the same process: a shared object is mapped in on first use
  and media_kit resolves libmpv exactly once per process, so replacing the file
  on disk changes nothing until Linthra starts again. That verdict is latched
  (so later plays are answered from the preflight instead of resolving a stream
  for an engine that has already failed) and its message says to restart
  Linthra rather than promising Retry will do it. Retry still makes one real
  attempt, because not every failure the engine reports after loading is the
  library's ABI.
* **Normal failures are untouched.** Only an error that actually names the
  native runtime (`libmpv`, an mpv symbol, the dynamic loader, an ELF header) is
  classified this way. A codec libmpv was not built with, a NAS that is asleep,
  an expired Jellyfin session and a stream that came back as a login page all
  keep the wording and the recovery they already had.
* **A bug stays a bug.** An error the classifier does not recognise is rethrown
  untouched rather than relabelled "install libmpv", which would send everyone
  who hit it to reinstall a package that was never the problem.

One limit is worth writing down. media_kit swallows each individual library
load failure and reports one fixed "cannot find libmpv" for all of them, so at
*registration* time a libmpv that is absent and one that is present and
refused are indistinguishable. Linthra could tell them apart by loading the
library itself, and deliberately does not: `scripts/check_pr_security_surface.py`
blocks runtime FFI outright, and a sharper error message is not worth an
exception to that rule. The missing-library wording therefore says "install or
reinstall", which is the right advice either way.

Nothing is lost for the case that actually bites. A libmpv that is present and
wrong gets through registration (the loader binds symbols lazily) and fails at
the first symbol it needs, and *that* error carries the real reason, so it is
classified as incompatible from the message itself with no library loading of
Linthra's own.

The loader's own message is kept for developers, with absolute paths and URLs
removed and the whole thing bounded onto one line, and it goes to the debug log
only. The copyable diagnostics report carries the closed-enum verdict instead
(`Backend runtime: libmpv not found`), so the report's "no free-form strings"
promise still holds.

| Piece | File |
| --- | --- |
| Classification, wording, sanitising | `lib/core/services/linux_playback_runtime.dart` |
| Registration and retry | `LinuxPlaybackBackendInitializer`, `lib/core/services/linux_playback_controller.dart` |
| The shared seams it plugs into | `engineUnavailableFailure` / `loadFailureFor`, `lib/core/services/just_audio_playback_controller.dart` |

### Volume

Desktop needs its own volume control: there are no hardware volume keys bound to
the app the way a phone has, and turning the whole system down to quieten one
player is not the same thing. Now Playing (beside the action row) and the wide
mini-player bar carry a mute button and a slider, with scroll-wheel and arrow-key
adjustment; both are hidden on mobile, on windows too narrow to hold them, and
while casting, where the receiver's own level is the Cast sheet's control.

The level lives on the playback seam, not in a widget: `PlaybackController`
gained `setVolume` / `setMuted`, and `PlaybackState` carries `volume` and
`muted`. So every way of changing it — either control, a shell's MPRIS slider,
the level restored at startup — moves the others, and nothing in the UI talks to
libmpv directly.

What the engine is actually set to is the listener's level *times* the current
track's ReplayGain (when normalization is on) *times* the audio-focus duck
factor, in `JustAudioPlaybackController.engineVolumeFor`. Automatic attenuation
therefore never moves the slider, and the slider never cancels a duck. Mute
keeps the level it was at, so unmute returns to exactly it.

The volume (never the mute) is persisted per install through
`PlaybackVolumePersistence` and restored at startup, sanitized to 0.0–1.0 on
both the way in and the way out — an out-of-range or non-finite stored value can
never reach the engine, and a launch is never silent for a reason nothing on
screen explains.

### Vendored `just_audio_media_kit`

`just_audio_media_kit` is vendored under `third_party/just_audio_media_kit`
(and wired in through a `dependency_overrides` path entry) rather than pulled
from pub.dev. The local delta is two small additions:

* `JustAudioMediaKit.mpvProperties`, an optional map of libmpv properties
  applied at player creation. Linthra uses it for the defaults below, and the
  headless CI smoke target layers its own `ao` on top where there is no
  PipeWire/Pulse device.
* `JustAudioMediaKit.livePlayers`, a map of the media_kit `Player`s that
  currently exist. just_audio's platform interface has no concept of an audio
  output device, and media_kit's `Player` is private to the plugin, so this is
  how [Audio output device](#audio-output-device) reaches libmpv's
  `audio-device-list` and `audio-device`.

### libmpv properties Linthra sets

`linuxMpvProperties` in `lib/core/services/linux_playback_controller.dart` is
the one place these live, and `resolveLinuxMpvProperties` merges anything a
caller already set on top of them.

| Property | Value | Why |
| --- | --- | --- |
| `cache-on-disk` | `no` | media_kit turns mpv's on-disk demuxer cache on for every player (`'cache-on-disk': 'yes'`, media_kit 1.2.6 `lib/src/player/native/player/real.dart`). That suits a video player buffering gigabytes; Linthra streams audio and manages its own offline downloads. Where mpv cannot create its temporary file — a sandbox, or a cache directory it cannot write — it logs `[lavf] Failed to create cache temporary file.` and `[lavf] Failed to create file cache.` on every stream ([#405](https://github.com/thezupzup/linthra/issues/405)). |

Only the temporary on-disk packet file is turned off. media_kit's `cache=yes`
stays, so memory and network buffering behave as before, and Linthra's own
download/offline cache is a separate mechanism that this does not touch.

Ordering matters and is not accidental: media_kit applies its own defaults while
the player initializes, and `just_audio_media_kit` applies `mpvProperties`
afterwards through `NativePlayer.setProperty`, which awaits that initialization.
The Linthra values therefore land last.

`third_party/just_audio_media_kit/PATCHES.md` records the exact upstream
version and archive digest, what is and isn't vendored, and how to refresh it.
`scripts/check_vendored_packages.sh` (run by CI and by
`scripts/verify_linux.sh`) analyzes the package from its own directory with the
pinned toolchain and proves — offline — that the tree is still upstream plus
that recorded patch.

### Audio output device

Settings → Music & playback → **Audio output** lists the outputs the host offers
(speakers, headset, HDMI, a USB DAC) and moves playback onto the one the
listener picks ([issue #402](https://github.com/TheZupZup/Linthra/issues/402)).
Nothing goes around the backend: the list *is* libmpv's `audio-device-list`, and
the choice *is* its `audio-device`. Android is untouched — output routing there
belongs to the system, so the seam reports itself unsupported and the card is
not rendered at all.

| Piece | File |
| --- | --- |
| The seam | `lib/core/services/audio_output_device_service.dart` |
| Linux implementation | `lib/core/services/linux_audio_output_device_service.dart` |
| Platform split | `lib/core/services/platform_audio_output_device_service.dart` |
| Policy (restore, fallback, hotplug, what is remembered) | `lib/features/settings/playback/audio_output_controller.dart` |

Four decisions worth knowing:

* **Switching moves audio that is already playing.** The chosen device is
  written to every live player through media_kit's `setAudioDevice`, *and* into
  `JustAudioMediaKit.mpvProperties`, so a player the engine creates afterwards
  (a stop/start, a suspend/resume reload, a source switch) starts on it too.
* **A missing device falls back, quietly and safely.** On launch the saved
  device is looked up in the list the host actually reports. If it is not there
  — unplugged headset, a different machine, a renamed sink — Linthra stays on
  the system default, forgets the stored value rather than pushing a name libmpv
  would reject, and the card says so.
* **"Did not answer" is never read as "device gone".** A backend that cannot be
  enumerated — including one that does not publish `audio-device-list` before
  the probe times out — clears nothing, re-routes nothing, and keeps the live
  selection; the card just reports that it found no outputs. libmpv seeds its
  own state with a lone `auto` entry, and treating *that* as the real list is
  exactly how a transient hiccup would look like an unplugged device, so the
  timeout is deliberately surfaced as a failure instead.
* **A refused switch is not recorded as done.** Routing reports whether it took
  effect. If the backend refuses (the device went away between the list and the
  tap) nothing is stored, playback is still shown where it actually is, the card
  says the switch did not happen, and the next attempt at that device is a real
  attempt rather than a no-op.
* **Choices are serialized.** Two quick picks queue instead of racing, so the
  later gesture is the one that ends up playing and stored.
* **Only stable ids are remembered.** PipeWire/PulseAudio node names and ALSA
  `CARD=` names are derived from the hardware and survive a reboot, so they are
  persisted. Numbers are not: ALSA's `alsa/hw:1,0` handles are card *indexes*
  that renumber when a USB DAC or dock is plugged in, and a bare numeric target
  (`pipewire/42`) is a runtime object id the daemon reuses for a different sink
  after a restart. The startup check can only ask whether a saved id still
  exists, and a reused number exists while meaning something else — so both are
  applied for the session and deliberately not stored, and the card explains
  that.
* **Launch never probes for nothing.** Asking libmpv for its device list is the
  only slow part, so it happens when the Settings card is opened, or at launch
  only when there is a saved device to restore. When nothing is playing there is
  no player to ask, so enumeration builds a short-lived libmpv handle and
  disposes it — reading the device list never opens an output or makes a sound.
* **The restore finishes before the first frame.** media_kit builds its player
  when the first track loads and reads the chosen output at construction, so a
  restore still in flight then would play the opening seconds on the system
  default before jumping. Bootstrap waits for it, bounded by a deadline
  (`_audioOutputRestoreDeadline`) so a wedged backend delays launch by that much
  and no more; past it the restore still lands and still moves live playback.

The mapping, the fallback and what gets remembered are covered by
`test/core/models/audio_output_device_test.dart`,
`test/core/services/linux_audio_output_device_service_test.dart` and
`test/features/settings/playback/audio_output_controller_test.dart`. What those
cannot cover is libmpv itself — `flutter test` runs on the Dart VM without the
native bundle, so a real `Player` is never built. Check that part on a real
desktop:

| Check | Expected |
| --- | --- |
| Open Settings → Music & playback with nothing playing | The list shows your real outputs, and no sound is produced while it enumerates. |
| Start a track, then switch output | The audio moves to the new device without the track restarting or losing its position. |
| Switch output, stop, play something else | The new track still comes out of the chosen device. |
| Plug in a headset, then press Refresh | The new device appears in the list. |
| Pick a USB output, quit, unplug it, relaunch | Playback uses the system default and the card says the saved output is unavailable. |
| Pick a USB output, quit, plug it back in, relaunch | Playback goes back to that output on its own. |

### Device hotplug

Devices come and go while music is playing: headphones are unplugged, a
Bluetooth speaker drops out of range and comes back, an HDMI sink appears when a
monitor wakes, the desktop moves its default sink
([issue #403](https://github.com/thezupzup/linthra/issues/403)). The same seam
handles all of it — `AudioOutputDeviceService.deviceChanges` is libmpv's
`audio-device-list` *observed* rather than read once, and the rules for reacting
live in `AudioOutputController` next to the ones that already decide which
output is chosen and whether it is remembered.

| The host does this | Linthra does this |
| --- | --- |
| A device appears | Adds it to the list. Playback is not moved. |
| An unrelated device disappears | Updates the list. Playback is not moved. |
| The system default moves, and nothing was chosen | Nothing. "System default" means the host decides, including when it changes its mind. |
| The chosen device is still listed | Nothing. libmpv carried playback through with no gap, and re-routing to a sink audio is already on would be an interruption caused purely by the recovery code. |
| The chosen device disappears | Falls back to the system default so audio stays audible, and the card says why it moved. The preference is **kept**. |
| The chosen device comes back | Hands playback back to it and clears the notice. |
| The fallback is refused too | Surfaces a recoverable "playback may be silent" state with a **Try again**, rather than leaving playback pointed at a sink that is not there. |

Three properties are what keep this from causing the bugs it is meant to fix:

* **Nothing is ever re-loaded.** Recovery is a *routing* decision: the queue,
  the track and the position are untouched, and no second player is created, so
  a device event cannot produce duplicate playback.
* **Exactly one subscription.** The controller opens one device-change
  subscription in `build` and closes it with the notifier, and the Linux service
  keeps at most one device-list listener per live player, keyed by the player
  id. One unplug is handled once.
* **Nothing polls.** The service re-attaches when the engine rebuilds its
  player, driven by the vendored plugin's `livePlayersChanged` signal
  (`third_party/just_audio_media_kit/PATCHES.md`) rather than by a timer.

**Memory remembers what disk forgets.** A saved output that was *never seen* on
this machine is dropped at launch — that is the "saved on another machine" rule
and it has not changed. But a device that has been playing this session and then
vanished is a hotplug, not a stale preference, so the preference survives it and
a reconnect restores the choice. Without that split, a Bluetooth dropout plus a
refresh would quietly lose what the listener picked.

**When nothing is playing there are no events.** Watching needs a live player,
and Linthra will not create one just to watch — a diagnostics or settings screen
that spun up a second libmpv handle would be the next bug. There is nothing to
recover in that state either, because no audio is being interrupted; the next
play, or the card's Refresh, picks up whatever changed.

`test/features/settings/playback/audio_output_hotplug_test.dart` drives every
row of the table above against a fake backend, including a flapping device over
repeated connect/disconnect cycles. On a real desktop:

| Check | Expected |
| --- | --- |
| Play something on the built-in output, plug in wired headphones | Audio keeps playing; the new device appears in the list without playback moving. |
| Choose the headphones, then unplug them mid-track | Audio continues on the system default, the track does not restart, and the card explains the move. |
| Plug them back in | Playback returns to them on its own. |
| Choose a Bluetooth speaker, walk out of range and back | Same: fall back, then hand back, with no duplicated audio and no restart. |
| Choose an HDMI output, put the monitor to sleep, wake it | Same. |
| Change the desktop's default sink while playing on "System default" | Audio follows the desktop; Linthra does not fight it. |

libmpv provides broad codec/container support and PulseAudio/PipeWire output.
It is a native runtime dependency, not a binary downloaded when Linthra starts.
The Flatpak manifest therefore builds libmpv as a declared module and bundles
it, so the packaged app needs no host libmpv at all
([flatpak-development.md](./flatpak-development.md)).
`media_kit_libs_linux` normally offers an optional build-time mimalloc download;
Linthra explicitly disables it in `linux/CMakeLists.txt`, so this backend adds no
undeclared network access to an isolated `flatpak-builder` build.

## Playback diagnostics

Settings → **Diagnostics & support** → **Linux playback** builds a copyable
report of what Linthra is playing through on this machine
([issue #406](https://github.com/thezupzup/linthra/issues/406)). It is a
separate card from the general Diagnostics one, shown on Linux only, so the
Android page is unchanged.

A typical report:

```
Linthra Linux playback diagnostics
Backend: media_kit / libmpv (just_audio_media_kit)
libmpv: available
libmpv version: mpv 0.38.0
mpv audio-device: set
mpv cache-on-disk: no
Output selection: supported
Outputs found: 4
Selected output: usb, via pipewire
Selected output remembered: yes
Suspend/resume recovery: enabled
Playback state: playing
Recent playback failures: load ×2
```

On a machine whose audio runtime is broken the report opens with the verdict
instead, so a bug report says which part of the stack is at fault before it
says anything else:

```
Linthra Linux playback diagnostics
Backend: media_kit / libmpv (just_audio_media_kit)
Backend runtime: libmpv not found
libmpv: not probed (nothing playing)
...
```

| Piece | File |
| --- | --- |
| The snapshot + renderer | `lib/core/diagnostics/linux_playback_diagnostics.dart` |
| Runtime classification | `lib/core/services/linux_playback_runtime.dart` |
| libmpv probe | `lib/core/services/linux_mpv_probe.dart` |
| Collector | `lib/features/settings/diagnostics/linux_playback_diagnostics_collector.dart` |
| The card | `lib/features/settings/diagnostics/linux_playback_diagnostics_section.dart` |

### Safe by construction, not by redaction

The report has no redaction pass, because there is nothing in the snapshot to
redact. Every field of `LinuxPlaybackDiagnosticsData` is one of four things: a
value from a closed enum, a bool, an int, or a version string that has already
been accepted by `sanitizeVersion`. There is deliberately no field for a stream
URL, a token, a header, a file path, a device node name, or a raw backend
error.

Three collection choices carry most of that:

* **The output device is never named.** libmpv's device id is
  `pipewire/alsa_output.usb-Topping_D10-00.analog-stereo`, and a Bluetooth sink
  is `pulse/bluez_output.AC_12_2F_…` — the adapter's MAC. The report says
  `usb, via pipewire` / `bluetooth, via pulse` instead: the driver comes from
  the prefix, the kind from a fixed substring match, and both results are enum
  constants. The string that was classified is not kept.
* **Failures come from `SafeEventLog`.** Those entries are already fixed
  structural labels (`load`, `resolution`, `timeout`) written by
  `StabilityDiagnostics`, which has no parameter for a raw error. The report
  aggregates them to kind + count. The raw engine error — the one value that
  can carry a tokenized URL — is not collected anywhere, which is why it cannot
  leak.
* **mpv properties are an allowlist.** Only `cache-on-disk`, `ao` and
  `audio-device` may appear; `audio-device` is shown as `set` rather than by
  value, and any value that is not a plain short token is shown as `set` too. A
  property added to the map later is invisible here until someone decides it is
  safe to show.

`sanitizeVersion` **rejects** rather than strips: stripping the punctuation out
of `mpv 1.0\nAuthorization: Bearer abc` would leave the words behind, which is
worse than saying nothing, so a value that is not version-shaped is dropped and
its line omitted.

`test/core/diagnostics/linux_playback_diagnostics_test.dart` and
`test/features/settings/diagnostics/linux_playback_diagnostics_collector_test.dart`
pin all of that, including that a hostile device id or version string cannot
put a secret marker into the output.

### Missing information is not an error, and a failure is not a value

Every optional line is emitted only when its value is known, and a *failure* is
reported as one rather than dressed up as an answer. Three states are kept
apart deliberately, because collapsing any pair of them hides the thing the
report exists to show:

| Situation | Reported as |
| --- | --- |
| Nothing playing, so no player exists to ask | `libmpv: not probed` |
| A player answered | `libmpv: available` |
| A player exists and libmpv would not answer it (timeout, wedged handle) | `libmpv: unavailable` |

The same rule applies to the output list. A successful enumeration always
contains at least the system default, so an empty list can only mean the
backend did not answer — reported as `Outputs found: unknown (the backend did
not answer)`, never as `Outputs found: 0`, which would read as a machine with
no sound card. A list that was never asked for simply omits the line.

The card never fails to render because something was unavailable.

The libmpv probe deliberately **never creates a player**: it asks a live one
for `mpv-version` and gives up otherwise. A diagnostics view that spun up a
second libmpv handle would be the next bug report.

### What needs a real Linux box

The pure parts (classification, sanitising, rendering, collection, the card)
run in `flutter test`. Two things do not, because they need libmpv actually
loaded:

| Check | Expected |
| --- | --- |
| Open the card with nothing playing | `libmpv: not probed`, and no sound is produced (no player is created to answer). |
| Start a track, then open the card | `libmpv: available` with a real version line, and the selected output's driver/kind matching the Audio output card. |
| Play something that fails (a server that is down), then open the card | The failure appears under `Recent playback failures` as a kind and a count, never as an error message or a URL. |
| Move libmpv out of the loader's path (or run with `LD_LIBRARY_PATH` pointing at an empty directory), start Linthra, press play | The player says libmpv is not installed and offers only Retry; the report shows `Backend runtime: libmpv not found`. Put libmpv back, press Retry, and the track plays without restarting the app. |
| Narrow the window to its 420 px minimum, or raise the desktop's text scale | The card's two actions stack instead of sharing a row, and the labels stay readable. |

## When a music folder can't be read

A configured local folder can stop answering for reasons that have nothing to do
with the user changing their mind, and until #414 they all looked the same: an
empty library, or one sentence about reselecting that was right about a third of
the time. Linthra now says which problem it is and offers the way out.

### Three problems, three fixes

The classification happens in exactly one place (`classifyFilesystemFault` in
`lib/core/sources/local/local_root_fault.dart`, the only code that looks at an
`OSError`), and everything downstream carries a `LocalRootFault`, never an
errno, a path or an OS message.

| What the user sees | When | Recovery |
| --- | --- | --- |
| **Folder not found** | The path is not there: the drive was unmounted, the folder was moved, renamed or deleted, or the Flatpak portal document that exposed it was revoked (`ENOENT`, `ENOTDIR`). | Reconnect the drive and Retry, or select the folder again if the music moved. |
| **Permission denied** | The folder is there and this process may not read it: directory permissions changed, or a grant was withdrawn (`EACCES`, `EPERM`). | Fix the permissions and Retry, or select the folder again through the chooser. |
| **Storage isn't responding** | The path resolves but the storage behind it does not answer: a network share that is down, a stale mount, a device returning I/O errors (`EIO`, `ESTALE`, `ETIMEDOUT`, `ENOTCONN`, …). | Reconnect it, or wait: Linthra re-asks an absent folder on its own and picks it up as soon as it answers. |
| **Folder can't be read** | Anything else. Deliberately *not* dressed up as one of the three above. | Retry, or select the folder again. |

An Android SAF tree and Android's device-wide MediaStore selection do not use the
filesystem wording at all: a `content://` tree cannot go missing, only lose its
grant, and the device library is not a folder and is never sent to a folder
chooser.

### Retry, Select folder again, Remove folder

All three sit on the folder's own row in **Settings → Local music**, and the
first two are repeated on the Library screen whenever a folder being away is the
reason there is nothing to show, whether it went away after a scan or could not
be read on the very first one (which leaves nothing indexed at all). Removing
stays on the Settings card, next to the sentence that says what it does and does
not do. While one of the three is running they all stand down, on the Library
screen as well as the card, so a second chooser or a competing scan cannot be
started on top of the first.

* **Retry** re-probes that folder, and waits for that probe even when the
  return-trip poll happened to be mid-round: reading the state from before the
  question was asked would tell a user who just plugged their drive back in that
  it is still gone. If it is still away, the card says so in the words of that
  folder's problem and nothing is written. If it answered, the ordinary
  incremental scan runs (the same one Rescan runs), so whatever changed while
  the folder was gone lands in the catalog. That scan runs once: a folder coming
  back is what the return trip already refreshes, so Retry does not walk the
  selection a second time on top of it.
* **Select folder again** opens the system chooser, and the folder it returns
  is asked whether it can be read *before* anything is scanned or saved: a
  replacement that cannot be read leaves the old folder, and the music indexed
  from it, exactly as they were. It is checked that early because a scan writes
  the catalog for the folders it was given, so a replacement that fails beside a
  folder that works would already have dropped the replaced folder's tracks by
  the time the scan reported it. This is the only way a configured path ever
  changes. Linthra never looks for where a drive went and
  never adopts a path on the user's behalf: it cannot prove a folder at a new
  mount point holds the same music, and guessing would aim the library at
  somebody else's files. Cancelling changes nothing.
* **Remove folder** drops that folder from the library and rescans what is left,
  so only its tracks go away. Every other folder, every server source, and every
  file on disk is untouched.

### What cannot happen

* **A temporary failure never costs the catalog anything.** A scan that could
  read nothing writes nothing, and a folder that failed inside a multi-folder
  scan keeps the tracks it already contributed, stamps and all. This is enforced
  by `LocalLibraryScan.isWritable`.
* **No folder is ever removed by going away.** Only the user removing it removes
  anything.
* **No user file is ever deleted, moved or written.** The seams the local library
  reaches storage through only list and read; there is no delete in them to call.
* **Folders are independent.** One drive being unplugged says nothing about the
  folder beside it, and nothing at all about Jellyfin, Navidrome/Subsonic or
  Plex.
* **No raw OS error reaches the UI.** The failure *kind* does reach the
  diagnostics line (`fault=permissionDenied` alongside the existing
  `error=folderUnavailable`), which is a fixed enum name and as safe to attach to
  a bug report as the rest of that line.

## Remaining Linux limitations

| Area | State | Why |
| --- | --- | --- |
| **Audio playback** | Supported | media_kit/libmpv through `LinuxPlaybackController`; local files and resolved Jellyfin, Navidrome/Subsonic, and Plex HTTP(S) streams share one backend. A libmpv that is missing, unloadable or incompatible is reported as such and retried in place ([issue #404](https://github.com/TheZupZup/Linthra/issues/404)), not as a track that would not play. See [When the audio engine itself won't start](#when-the-audio-engine-itself-wont-start). |
| **Suspend / resume** | Supported (app side); real device/sink timing varies | Lifecycle `paused`→`resumed` arms a bounded Linux-only reload of an actively playing track after a short backoff ([issue #466](https://github.com/TheZupZup/Linthra/issues/466)). See [Suspend / resume (manual matrix)](#suspend--resume-manual-matrix). |
| **Light/Dark/System theme** | Supported (app side); the native brightness bridge itself is Flutter's, not independently verified here | Settings → Appearance's System/Light/Dark choice ([issue #459](https://github.com/TheZupZup/Linthra/issues/459)) is the same shared `ThemeModePreference`/`ThemeModeController` Android uses, mapped onto `MaterialApp`'s own `themeMode` — no `gsettings`/D-Bus/GNOME/KDE-specific code in Linthra itself, and no separate Linux theme path (`test/app/theme_mode_test.dart` proves that). *Supplying* System's brightness on Linux is Flutter's GTK embedder (via the XDG desktop portal or a GNOME GSettings fallback); that native bridge is outside Linthra's code and isn't exercised by `flutter test`, which runs on the Dart VM and injects brightness straight into Flutter's test `PlatformDispatcher`. Reproducing the real bridge deterministically in CI would need a running portal daemon or GNOME schemas — exactly the DE-specific setup this app avoids adding — so it stays untested here and is a known gap, not a claimed guarantee. Rows B1 and B2 of the [compatibility matrix](./desktop-compatibility-matrix.md#b-appearance) are where that bridge is exercised by hand, on both desktops. |
| Media session / MPRIS | Supported | `PlatformMediaSessionBinding` routes Linux to `MprisMediaSessionBinding`, which exports `/org/mpris/MediaPlayer2` and owns `org.mpris.MediaPlayer2.linthra` ([issue #397](https://github.com/TheZupZup/Linthra/issues/397)). Shells get PlaybackStatus, Metadata, Position and the transport methods; media keys work through the same interface. `Volume` is read/write, so a shell's own volume slider drives Linthra's level (and reads zero while muted); `Rate` stays honestly read-only. `Raise` and `Quit` are answered too, so a listener whose window is hidden by background mode can bring Linthra back or shut it down from the shell's media widget (#401). `audio_service` is still never initialised on Linux — it stays the Android delegate. A machine with no session bus simply gets no desktop controls. |
| Close-window behaviour | Supported | Settings → Music & playback → Desktop window chooses between quitting and keeping playback running ([issue #401](https://github.com/TheZupZup/Linthra/issues/401)). The runner answers the close, Dart decides what the answer should be, and background mode only ever starts while audio is actually playing. See [Closing the window](#closing-the-window). |
| Android Auto | Android-only, by design | It is an Android platform integration, not a Linthra feature. |
| Media notification + `POST_NOTIFICATIONS` | Android-only, by design | There is no equivalent gate on Linux; desktop controls come from MPRIS instead, and a Linux notification needs no runtime permission. |
| Track change notifications | Supported, off by default | Settings → Music & playback → Desktop notifications shows a short notification when the song changes ([issue #400](https://github.com/TheZupZup/Linthra/issues/400)). D-Bus, through the Notification portal where there is one and `org.freedesktop.Notifications` otherwise, so it works in the Flatpak without widening the sandbox. Android is untouched: its per-track notification is the media session's. See [Track change notifications](#track-change-notifications). |
| Android audio focus | Android-only, by design | `JustAudioPlaybackController` already scopes its focus handling to Android/iOS. |
| SAF (`content://` folders) | Android-only, by design | Linux picks a real filesystem path. The scanner's desktop path is the one that runs. |
| Folder chooser | Supported | Linthra's own runner channel (`linux/runner/folder_picker_channel.cc`) opens `GtkFileChooserNative`: the ordinary GTK dialog natively, and the xdg-desktop-portal chooser inside the Flatpak, where `file_picker`'s `zenity`/`kdialog` do not exist ([issue #438](https://github.com/TheZupZup/Linthra/issues/438)). `scripts/check_linux_runner.py` holds the runner's channel name to the Dart side's. |
| Multiple music folders | Supported | Settings → Local music takes several folders and scans them as one library ([issue #412](https://github.com/TheZupZup/Linthra/issues/412)). A folder selected inside another one is walked once, removing a folder removes only its tracks, and an existing single-folder selection carries over as the first folder. Android keeps its single SAF/MediaStore selection. |
| Lost folder access | Supported | A selected folder that stops being readable says *which* problem it has (not found, permission denied, or storage not responding) and offers Retry, Select folder again and Remove folder on that folder's row ([issue #414](https://github.com/TheZupZup/Linthra/issues/414)). The indexed catalog is left alone rather than replaced with an empty scan, and the Library screen explains the same thing instead of looking empty. With several folders, the readable ones still refresh while the unreachable one keeps the tracks it already contributed. See [When a music folder can't be read](#when-a-music-folder-cant-be-read). |
| **Removable music drives** | Supported | A music folder on a USB disk or external SSD that is unplugged becomes *temporarily unavailable*, never deleted ([issue #415](https://github.com/TheZupZup/Linthra/issues/415)): the folder stays selected, its tracks stay indexed, the other folders and every server source keep working, and playing one of its files fails cleanly with the queue intact. While a folder is away Linthra re-asks that path every few seconds (and polls nothing at all while every folder is present), so plugging the drive back in re-opens its filesystem watch and runs the ordinary incremental rescan with no reconfiguration. Availability is derived from the configured path alone (no mount-point scanning, no automounter or GNOME/KDE-specific paths), so a drive that returns at a *different* path is deliberately not adopted: the configured folder stays unavailable until it is mounted where it was or the new folder is selected. |
| Local tag reading | Supported | `FilesystemLocalMetadataReader` reads title, artist, album artist, album, track number and duration from ID3, Vorbis comments, MP4 atoms, APEv2 and RIFF INFO through `audio_metadata_reader` ([issue #407](https://github.com/TheZupZup/Linthra/issues/407)). An unreadable or untagged file still appears, from its filename. Android is deliberately unchanged: its tags come from the native SAF walk. |
| Local embedded artwork | Unsupported | Tags are read without pulling cover images out of every file during a scan. Extracting and caching embedded art on desktop is [issue #408](https://github.com/TheZupZup/Linthra/issues/408); tracks keep the placeholder until then. |
| **Audio output device** | Supported | Settings → Music & playback → Audio output lists libmpv's `audio-device-list` and routes playback with `audio-device` ([issue #402](https://github.com/TheZupZup/Linthra/issues/402)). A saved device is re-applied at launch, and one that is no longer present falls back to the system default. See [Audio output device](#audio-output-device). |
| **Device hotplug** | Supported | A headset, Bluetooth speaker or HDMI sink appearing or disappearing mid-playback is recovered without restarting the track or creating a second player, and a chosen device that comes back takes playback back ([issue #403](https://github.com/thezupzup/linthra/issues/403)). If even the system default is refused, the card says so and offers a retry. See [Device hotplug](#device-hotplug). |
| **Playback diagnostics** | Supported | Settings → Diagnostics & support → Linux playback builds a copyable report of the backend, libmpv, the selected output subsystem and recent failure kinds ([issue #406](https://github.com/thezupzup/linthra/issues/406)). Safe by construction: no field can hold a URL, token, header, path, device name or raw error. See [Playback diagnostics](#playback-diagnostics). |
| Chromecast | Android/iOS only | Already gated in `cast_providers.dart`; Linux keeps the honest "cast unavailable" service. |
| Share sheet, launcher-icon switching | Android-only, by design | No desktop equivalent; the UI simply omits them. |
| Volume control | Supported | A mute and a slider on Now Playing and the wide mini-player bar, plus MPRIS `Volume`, driven through `PlaybackController` and remembered across launches ([issue #394](https://github.com/TheZupZup/Linthra/issues/394)). See [Volume](#volume). |
| Desktop layout | Supported | The shell swaps its bottom bar for a navigation rail at 900 px, and feature screens adapt on the width they are given, including a third pane for the Library grids and for Now Playing's queue. On a wide enough window the shell can also keep the queue as a column beside the page ([issue #416](https://github.com/TheZupZup/Linthra/issues/416)). See [How the desktop layout adapts](#how-the-desktop-layout-adapts). |
| Window geometry | Supported | Size and maximized state survive a restart; position too, on X11. A saved position is re-checked against the monitors attached now. See [Window state](#window-state). |
| Content density | Supported | Compact by default, switchable to Comfortable in Settings → Appearance and remembered across restarts ([issue #395](https://github.com/thezupzup/linthra/issues/395)). Both are Material `VisualDensity` values, so the choice reaches every list row, grid and control at once. Touch builds are unaffected. See [Density (Compact / Comfortable)](#density-compact--comfortable). |
| Pointer affordances | Supported | Compact content density, visible hover feedback, right-click context menus with a keyboard equivalent, and Ctrl/Shift multi-select in track lists — all keyed on the input rather than the window width. See [Pointer, not width](#pointer-not-width). |
| Keyboard navigation | Supported | The whole UI is reachable without a pointer: predictable Tab/Shift+Tab order, a strong accent focus ring distinct from hover and selection, Enter/Space activation, arrow keys through lists and grids with Home/End at their ends, and panes and dialogs that hand focus back when they close ([issue #390](https://github.com/TheZupZup/Linthra/issues/390)). Shared helpers in `lib/shared/focus/`, keyed on the input device rather than the platform, so touch is untouched. See [Keyboard navigation](#keyboard-navigation). |
| Keyboard shortcuts | Supported | App-wide transport and navigation chords, remappable in **Settings → Music & playback → Keyboard shortcuts** ([issue #391](https://github.com/TheZupZup/Linthra/issues/391)): play/pause, next, previous, quick search (**Ctrl+K**, with **Ctrl+F** as a fixed alias, [issue #393](https://github.com/TheZupZup/Linthra/issues/393)), library, queue and Now Playing. They stand down while a text field wants the key, and media keys stay with MPRIS rather than being bound a second time here. The volume control still takes the wheel and arrow keys only when focused; a global volume chord is not offered. See [Keyboard shortcuts](#keyboard-shortcuts) and [Quick search](#quick-search-ctrlk). |

Nothing in that table is faked. Each one is an explicit implementation behind an
existing interface, so it is visible in the code and covered by tests — with
one caveat: the Light/Dark/System theme row's *app-side* wiring is covered, but
the native GTK/portal brightness bridge underneath it is Flutter's own
responsibility and is not, and cannot easily be, exercised by `flutter test`;
see that row for why.

## How platform selection works

Linthra picks platform implementations behind interfaces, never with a
`Platform.isLinux` check inside a widget. Two pieces make that testable:

* **`HostPlatform`** (`lib/core/platform/host_platform.dart`) — the platform as
  a value rather than a `dart:io` read. Production uses `HostPlatform.current`;
  tests pass `HostPlatform.android` or `HostPlatform.linux`, so *both* branches
  of every seam can be asserted from one machine.
* **`hostPlatformProvider`** (`lib/data/repositories/host_platform_provider.dart`)
  — the same value for provider-level selection, overridable in a
  `ProviderContainer`.

The seams that branch on it:

| Seam | Android | Linux |
| --- | --- | --- |
| `PlatformMediaSessionBinding` | `audio_service` session | inert, never touches `audio_service` |
| `localPlaybackControllerProvider` | `JustAudioPlaybackController` (ExoPlayer) | `LinuxPlaybackController` (media_kit/libmpv) |
| `PlatformFolderPickerService` | SAF tree picker | runner GTK chooser (`GtkFileChooserNative`), which GTK routes to xdg-desktop-portal inside the Flatpak; `file_picker` only as a fallback |
| `PlatformAudioFileScanner` | SAF content-resolver walk | `dart:io` walk |
| `safDocumentListerProvider` | native content resolver | unsupported |
| `safPermissionProbeProvider` | native grant probe | unsupported |
| `localLyricsReaderProvider` | SAF sibling document | filesystem sibling |
| `PlatformShareService` | `ACTION_SEND` | no-op |
| `PlatformLauncherIconService` | `<activity-alias>` toggle | no-op |

Adding a platform-specific behaviour means adding a row here, not a check in a
widget.

## How the desktop layout adapts

Presentation is the one thing that does *not* branch on `HostPlatform`. Layout
adapts on the **width a widget is actually given**, so the same window is laid
out the same way wherever it runs, and a Linux window narrowed to 600 px gets
the phone layout rather than a cramped desktop one.

`lib/shared/layout/adaptive_layout.dart` holds the whole vocabulary:

| Piece | What it does |
| --- | --- |
| `WindowSizeClass` | `compact` (< 600), `medium` (< 1000), `expanded` (< 1600), `large` — Material's window size classes, with the phone thresholds left where Android already behaves |
| `windowSizeClassFor(width)` | the pure breakpoint function, so the thresholds are unit-testable |
| `AdaptiveLayoutBuilder` | resolves the class from the widget's own `BoxConstraints` — inside the desktop shell a screen is narrower than the window by the navigation rail, and a pane is narrower still |
| `AdaptiveContentWidth` | caps and centres a single column (`maxContentWidth`, or `maxFormWidth` for settings), a no-op below the cap |

`lib/shared/layout/pane_layout.dart` holds the compositions built out of those:

| Piece | What it does |
| --- | --- |
| `SplitPanes` | two panes with a hairline between them, one at a fixed width and one taking the rest, capped and centred — the shape a header pane beside a scrolling list and a grid beside a detail both want, written once |
| `ListDetailPanes` | a list or grid that gains a detail pane once its own box is wide enough, and tells the list which mode it is in so a tap can select into the pane or push a route |
| `DetailPanePlaceholder` | the calm "nothing picked yet" state, so the pane holds its width instead of making the grid reflow on every click |

What it buys, per surface:

* **Album grid** — cards stay between 200 and 260 logical px and the grid adds
  columns instead of inflating covers: 5 across at 1280, 7 at 1920, 10 at 2560,
  where before every desktop width got the same six mobile-sized cards.
* **Artists** — the same rows flow into 2–5 columns rather than one row per
  monitor width.
* **Songs, playlists, downloads, settings** — one column, capped and centred,
  so a title and its trailing action never end up a screen apart.
* **Album and artist detail** — at `expanded` and up, a persistent left pane
  (cover/portrait, counts, Play and Shuffle) beside the scrolling track list.
  Selection mode falls back to the single column.
* **Albums and Artists, three panes** — past `listDetailMinWidth` the grid keeps
  its place and the album (or artist) opens *beside* it, so browsing a shelf is
  a click each rather than a click and a trip back. With the shell's navigation
  rail that is navigation · content · detail. Below the split width the same
  screen is pushed as a route, exactly as before. The selection lives on the
  Library screen rather than in the pane, so dragging a window across the
  threshold moves the detail between a pane and a page without resetting it.
* **Now Playing** — at `expanded` and up, the cover sits beside the metadata
  and transport, and lyrics open *next to* the cover instead of replacing it.
  Same `_showLyrics` state and same playback state as the stacked layout. Wider
  still, the queue joins them as a third column instead of a sheet over the top,
  so lyrics and up-next are readable at once; the action row's queue button
  becomes the pane toggle, and narrower windows keep the sheet.
* **The queue, beside the page**: past `queueSidePanelMinWindowWidth` the
  frame itself can hold the queue as a column on the right, so up-next stays
  readable while you browse the library. The now-playing bar's queue button is
  its toggle there (and still opens the sheet at every narrower width), the
  column is closed until asked for, and it is the same `QueueSheet` the phone
  opens as a sheet: one queue, three hosts. The threshold is what it takes for
  all three columns to be worth having: the panel's 340 px, the rail beside it,
  and a page still wide enough to split into list and detail. Narrow the window
  and the column goes; widen it and it comes back where you left it.
* **The now-playing bar** — on a desktop host the progress line along its top
  edge is a seek control, not a readout: the same `PlaybackProgressBar` the full
  player uses, at its compact density and without the time caption. Width alone
  does not promote it — a tablet in landscape is as wide as a desktop window and
  still driven by a thumb.

Both breakpoints in the app agree by construction: the shell swaps its bottom
bar for the navigation rail at 900 px of window, and a feature screen inside it
only reaches `expanded` once the space left over is 1000 px wide.

### Source status in the sidebar

Under the rail's destinations, each **configured** self-hosted source (Jellyfin,
Navidrome/Subsonic, Plex) carries a small indicator: a glyph, the server's safe
name, and a tooltip. It answers the question the rail could not — *is my music
actually going to play?* — without a trip to Settings.

Four states, sharing their words and their glyphs with the library row's
`TrackStatusGlyph` so a row and the sidebar can never tell you different
stories about one server:

| State | Reads as | Tone |
| --- | --- | --- |
| `available` | "Jellyfin connected" | muted — a working server is not news |
| `checking` | "Checking Jellyfin" | muted |
| `unreachable` | "Jellyfin unavailable" | error colour |
| `authenticationError` | "Jellyfin sign-in needed" | error colour |

Activating a row opens the existing **Connections** screen (`go`, not `push`, so
the rail is not left highlighting Library while a Settings page is on screen).

What makes it safe to have on screen all the time:

* **Derived, never probed.** Everything comes from
  `configuredSourceStatusesProvider`, which reads the availability the probe
  controllers already publish and the sessions the settings controllers already
  hold. No row owns a timer, a client or a request, so a second row costs
  nothing again. Rendering the strip issues no network call — there is a test
  that counts.
* **No flicker.** The probe controllers publish `checking` only when nothing is
  known yet (a cold start, a fresh sign-in) and never on an ordinary re-probe,
  which writes its settled answer directly. A server that is merely being polled
  stays "connected" instead of blinking through a spinner every 45 seconds.
* **Isolated.** Each row resolves from its own source's state alone, so Jellyfin
  going away cannot mark Plex offline.
* **Quiet when healthy.** Nothing configured means no strip at all, and a
  healthy source sits in the same muted tone as the rest of the rail's chrome.
  Only a source that needs you takes the error colour.
* **Secret-free.** The only source-identifying text that reaches the widget is
  the fixed name from `PlaybackSourceLabel` ("Jellyfin", "Navidrome", "Plex").
  There is no field a server URL, hostname, username, token or raw exception
  string could travel in.
* **Desktop chrome.** It lives in the rail, so a phone never grows one and a
  Linux window narrowed below 900 px loses it with the rail.

A source that publishes no availability of its own yet (Navidrome and Plex
today) falls back to "configured, and therefore assumed reachable" — what the
rest of the app already assumes about it. When one adopts the probe the way
Jellyfin did, its indicator becomes real with no change to the sidebar.

Where the deeper connection-management view goes is #427; this is only the
indicator and the route to what already exists.

### Pointer, not width

Three things adapt on the **input** rather than on the window, because that is
what they are actually about. A tablet in landscape is as wide as a desktop
window and is still driven by a thumb.

* **Content density** — the theme uses `VisualDensity.adaptivePlatformDensity`,
  Material's own adaptive value: compact on Linux/macOS/Windows, standard
  everywhere touch-first. The two places that sized rows with a hard-coded
  number follow it rather than ignoring it — the songs list's fixed row extent
  (which the A–Z index measures its scroll offsets in) and the artist grid's
  cell floor — and both only give back padding, never room the words need.
  On desktop the value is also a **preference**: see
  [Density (Compact / Comfortable)](#density-compact--comfortable).
### Density (Compact / Comfortable)

Settings → Appearance → **Density** offers two desktop densities
([issue #395](https://github.com/thezupzup/linthra/issues/395)):

| Mode | Material value | Effect |
| --- | --- | --- |
| **Compact** (default) | `VisualDensity.compact` | What a desktop build has always looked like. Fits the most of a library per screen. |
| **Comfortable** | `VisualDensity.comfortable` | One step back towards the touch layout: roomier rows and grids, still denser than a phone. |

The preference is *only* a choice between two of Material's own
`VisualDensity` values — there is no second spacing scale. That is what makes
it reach the whole app for free: every widget that already reads
`Theme.of(context).visualDensity` (list rows, buttons, popup menus, the songs
list's row extent, the artist grid's cell floor) follows it with no change of
its own, and Material's minimum tap targets still apply on top, so neither
setting can shrink a control below a real click target.

| Piece | File |
| --- | --- |
| The preference | `lib/core/models/desktop_density.dart` |
| Store seam | `lib/core/repositories/desktop_density_store.dart` |
| Persistence | `lib/data/repositories/shared_preferences_desktop_density_store.dart` |
| Controller + `VisualDensity` mapping | `lib/features/appearance/desktop_density_controller.dart` |
| The card | `lib/features/appearance/desktop_density_card.dart` |

Two rules keep touch out of it. The card renders nothing off desktop, and
`LinthraApp` passes a density to `AppTheme` **only** on a desktop host — off
desktop the parameter is null and the theme keeps
`VisualDensity.adaptivePlatformDensity` exactly as before. An Android build can
therefore never inherit a desktop density, which
`test/features/appearance/desktop_density_widget_test.dart` pins.

Like the theme mode, the stored value is read before `runApp` so the first
frame already lays out at the chosen density; changing it afterwards rebuilds
both themes and relayouts every screen at once, with no restart.

* **Hover** — `hoverColor` carries enough weight to be seen on a black-first
  theme, and every ink surface picks it up at once: list rows, buttons, grid
  cards, rail destinations, menu items. It is neutral rather than brand-tinted,
  because the violet tint is what *selected* means.
  `HoverHighlight`/`HoverArtworkVeil` in `shared/widgets` cover the one case ink
  cannot: an album cover hides the overlay painted on the Material behind it.
* **Right-click and modifier-click** — `ContextMenuRegion` opens a surface's
  existing menu on secondary click and on the keyboard's menu key (or
  Shift+F10), and `TrackSelection` reads Ctrl/Cmd and Shift off the hardware
  keyboard at tap time. Nothing is gated on a platform, so a keyboard case on a
  tablet gets both for free and a bare touch tap is unchanged.
* **Scrolling** — the wheel, the trackpad and the sliders they land on, in one
  shared policy rather than a Linux check per list. See
  [Mouse wheel and trackpad](#mouse-wheel-and-trackpad).

### Context menus and multi-select

Right-clicking a row opens the list that surface already had, built at open time
so it reflects the state as it is then. Track rows share one list and one
dispatcher with their 3-dot button, so a right-click cannot offer an action a
tap cannot; they also gain **Show album** and **Show artist**, routed through the
same derived ids the grids use and offered only where the tags give somewhere to
go. Albums and artists get **Play · Shuffle · Play next · Add to queue · Add to
playlist**, each a command their detail pages already call. Playlists reuse
their rename/delete pair.

Multi-select follows the rules every desktop list has. Ctrl-click (Cmd on macOS)
picks one row out and starts a selection when there is none; Shift-click takes
everything between. `TrackSelection` (`lib/features/library/track_selection.dart`)
owns both, keyed by the provider-namespaced uri so two providers' same-id copies
can never be selected together, and it resolves a bulk action against the list
*as shown* — so a row that a search or a removal has taken off screen can never
be acted on. A range is computed over the list the clicked row is in, which for
the songs tab is the A–Z view's own sorted order rather than whatever the screen
handed it. Starting a selection hands the screen the keyboard, so Escape leaves
it. Long-press still does what it always did, so nothing about a phone changes.

### Keyboard navigation

Everything on the Linux UI can be reached and operated without a pointer
([#390](https://github.com/TheZupZup/Linthra/issues/390)). None of it is a
Linux branch: the pieces below are keyed on the *input device* or on the box a
widget is given, the same rule the rest of the desktop work follows, so a phone
behaves exactly as it always has and an Android tablet with a keyboard case
gets the lot for free.

- **Tab and Shift+Tab** walk the frame the way it reads: the page pane by pane,
  then the queue column, the navigation rail and the mini-player. The shell
  orders those groups explicitly (`HomeShell`), because the default
  reading-order policy sorts a rail beside a page by geometry and splits it
  around the content.
- **A focus ring** in the accent colour marks whatever holds the keyboard.
  Focus gets its own vocabulary on purpose: hover is a neutral veil and
  selection is an identity tint, and a third veil would leave all three saying
  roughly the same thing. `FocusRing`
  ([`lib/shared/focus/focus_ring.dart`](../lib/shared/focus/focus_ring.dart))
  draws it as an overlay, so it is visible even on an album cover, where
  Material's ink highlight is painted on the surface *behind* the card. It is
  drawn only while the focus manager is in keyboard/mouse mode, which is what
  keeps it off a touch build without a platform check.
- **Enter and Space** activate whatever is focused, which is Material's own
  behaviour for every ink surface and is pinned by tests on the library rows
  and the album grid.
- **The arrow keys** move through lists and grids, row by row and cell by cell,
  scrolling as they go.
- **Home and End** jump to the ends of a collection. They have to be added:
  in a lazily-built list the far end has no focus node for a traversal policy
  to find until something scrolls it into range. `ListKeyboardNavigation`
  ([`lib/shared/focus/list_keyboard_navigation.dart`](../lib/shared/focus/list_keyboard_navigation.dart))
  scrolls first and takes the outermost row at that end on the next frame. The
  same widget lets **← / →** carry on into the next row of a grid of cards, the
  way a desktop icon grid is walked. A focused text field is left alone
  outright, so Home, End and the arrows keep meaning what they mean while
  typing.
- **Panes hand the keyboard back.** Closing the queue column, the Now Playing
  queue pane or the Library detail pane disposes everything inside it, and
  Flutter unwinds focus to the route's scope: nothing is ringed and the next
  Tab starts again at the top of the page. `FocusHandoff`
  ([`lib/shared/focus/focus_handoff.dart`](../lib/shared/focus/focus_handoff.dart))
  puts it back on the control that reopens the pane, or on the list the detail
  was sitting beside. It fires only when the pane really was holding focus, and
  a window narrowed past a pane's width floor counts the same as pressing its
  close button.
- **Dialogs** trap Tab while they are open and give focus back to the control
  that opened them, which is Flutter's own modal behaviour; the tests pin it so
  a future change cannot quietly drop it.

Tests: `test/shared/focus/`, `test/features/library/keyboard_navigation_test.dart`,
`test/features/library/library_detail_pane_test.dart`,
`test/features/settings/provider_form_keyboard_test.dart`,
`test/features/shell/home_shell_focus_order_test.dart`,
`test/features/shell/queue_side_panel_shell_test.dart`,
`test/features/player/player_queue_pane_test.dart` and
`test/shared/widgets/confirm_dialog_test.dart`. Between them they cover forward
and backward traversal, activation, list and grid movement, the two pane
closures, dialog trapping and restoration, and a touch build behaving exactly
as it did before.

Configurable shortcuts are a separate job
([#391](https://github.com/TheZupZup/Linthra/issues/391)); what is bound today
is in the row above.

### Mouse wheel and trackpad

Scrolling is the part of a desktop app nobody notices until it is wrong
([#396](https://github.com/TheZupZup/Linthra/issues/396)). The rule is the one
the rest of the desktop work follows: **no widget branches on Linux**. There is
one scroll policy for the app and three small shared widgets, all of them keyed
on the *input signal* rather than on the host, so an Android phone is unchanged
by construction.

`lib/shared/scroll/`:

| Piece | What it does |
| --- | --- |
| `AppScrollBehavior` | the app's single `ScrollConfiguration`, installed on `MaterialApp` so it reaches every list, grid, sheet, pane and dialog at once |
| `pointer_scroll_policy.dart` | the arithmetic: what one wheel notch is, which axis owns which delta, and `WheelNotches`, which counts a trackpad's stream of small deltas into whole notches |
| `PointerScrollAdjust` | makes a control answer the wheel — and *take* it, so the page behind it stays put |
| `HorizontalWheelScroll` | lets a plain vertical wheel move a surface that only goes sideways |

**What `AppScrollBehavior` settles.** A pointer host clamps at the ends of a
list and draws no overscroll glow or stretch: that decoration answers "your
finger is still dragging, the list is not", and a wheel notch asks no such
question. Android keeps the physics and the stretch it always had, and Apple's
platforms keep their rubber band, which is native there rather than a mobile
import. A mouse is deliberately **not** a drag device: press-and-move with a
mouse means selecting, or dragging a row to a playlist, and a list that
scrolled out from under that would make both unusable. Touch, both stylus kinds
and the trackpad all still drag, which is what keeps a two-finger pan one smooth
gesture. Two of those three answers are what Material gives today; they are
written down anyway, so a stray `ThemeData.platform` or a future default cannot
quietly move them.

**Which axis owns which input.** A surface reads only the axis it scrolls
along, which is Flutter's own rule and the reason a sideways trackpad flick over
the songs list does nothing at all. The single exception is a genuinely
horizontal surface — today the Audiobookshelf library picker — where a mouse
with one wheel would otherwise have no way to reach the far end of the row.
`HorizontalWheelScroll` claims a *vertical-only* signal there, leaves a device
that can scroll sideways to the surface's own `Scrollable`, and stops claiming
once the row is at that end so the wheel carries on down the page instead of
the shelf swallowing it.

Only a **mouse** gets its vertical scrolling borrowed. A wheel has one axis and
no way to ask for the other; a trackpad has both, so a deliberate vertical
two-finger swipe over the row means vertical and is passed on rather than
turned sideways. On Linux the embedder may report a trackpad's scrolling as a
mouse's, in which case that rule changes nothing in practice there — it is
still the right rule to write down, and it is what makes the behaviour correct
wherever the two can be told apart.

Where the shelf is nested *inside* a scrolling page that last part needs no
help: the page is an ancestor, so an unclaimed signal reaches it on the way
out. The audiobook browser is not that shape — its chip row and its book list
are siblings in a column, and an unclaimed signal there reaches nothing at all,
because the list is not on the pointer's hit-test path. That is what
`HorizontalWheelScroll.chainTo` is for: hand it the list's controller and a
notch at the end of the row scrolls the books, the way the same strip behaves
in every other desktop app.

**Sliders.** Reading a scroll signal is not the same as taking it: a `Listener`
that answers the wheel still lets the ancestor `Scrollable` scroll as well, so
one notch over the volume slider used to change the volume *and* scroll the
library out from under the pointer. `PointerScrollAdjust` registers with the
`PointerSignalResolver` first — signals are dispatched from the innermost hit
target outwards, and the first registration wins — which is also what a real
toolkit does: a GTK scale answers the wheel and the window behind it stays
where it was. While a slider is actually being held it goes further and
swallows every scroll signal in the app, because mid-drag the pointer wanders
off a 14 px seek line easily and a notch that lands anywhere else would scroll
whatever is underneath.

That shield is the most destructive thing in this directory — a stuck one
would stop the whole app scrolling — so it is not left to a control
remembering to say when it is done. It needs a pointer that went down on the
control and has not come back up, and the pointer's own up or cancel (Flutter
guarantees one or the other) is what takes it away. A control whose drag state
gets stuck can still be wrong about itself; it cannot stop the rest of the app
scrolling. A keyboard or assistive adjustment installs no shield at all: it is
over the instant it happens.

One notch does what one arrow-key press does, so the wheel and the keyboard
agree: 5% of the range on volume, and 5% of the track (never less than five
seconds) on the seek bar, which `WavySeekBar.seekStepFor` owns for both. A
trackpad's forty small deltas are the same physical gesture as one wheel click
and are worth one step, not forty — stepping per event is what used to take a
two-finger flick from half volume to silence.

A partial notch is carried so that slow scrolling still gets somewhere, but
only within one gesture. A trackpad has no "I let go" in a scroll event —
fingers lifting look exactly like a pause — so `WheelNotches.gestureGap` (half
a second, measured on the events' own clock) ends one: long enough that
deliberate slow scrolling keeps adding up, short enough that a small swipe is
never completed by an unrelated one later.

**Fractional scaling.** A notch is measured in logical pixels, and the
framework divides the engine's physical delta by the device pixel ratio before
a widget sees it, so the same physical wheel click is the same step at 100%,
125%, 150% and 200%. Nothing here applies a correction factor, which is the
point: there is none to get wrong.

Tests: `test/shared/scroll/` covers the arithmetic, the behaviour's answers per
platform (including that Android resolves exactly what Material would give it),
the claim, the shield and the two ways it goes away, the horizontal shelf and
both shapes of chaining, and one step per notch at four display scales. `test/app/desktop_scroll_test.dart` is
the audit — the songs list, the albums and artists grids, an album and an
artist page beside their panes, playlists, the settings hub, the queue sheet
and a dialog each get one notch and have to move exactly one surface by exactly
one notch, plus the seek bar taking the wheel off the page, and Android still
dragging with a finger and still stretching at the end.

### Quick search (Ctrl+K)

**Ctrl+K** (or **Ctrl+F**) opens a quick-search overlay over whatever is on
screen: one box across songs, albums, artists and playlists, grouped and fully
keyboard-driven (↑/↓ to move, Enter to open, Esc to close). The screen
underneath keeps its state — it is a dialog on the root navigator, not a
navigation — and opening a result goes through the app's existing routes and
playback actions.

Like the layout, it is **not** gated on `HostPlatform`: the binding lives in the
shortcut registry below, which wraps the router above every route and can only
fire when a real keyboard sends the chord — so a phone is unaffected while an
Android tablet with a keyboard case gets it for free. What it searches and how
it ranks is documented in [library.md](./library.md#quick-search-ctrlk).

Tests: `test/shared/layout/adaptive_layout_test.dart`,
`test/features/library/album_grid_test.dart`,
`test/features/library/artist_grid_test.dart`,
`test/features/library/detail_desktop_layout_test.dart`,
`test/features/player/player_desktop_layout_test.dart` — each covers the phone
width alongside 1280, 1920, 2560 and ultrawide, so a change that only looks
right on one monitor fails.

### Keyboard shortcuts

Seven actions are bound out of the box, and every one of them can be remapped
in **Settings → Music & playback → Keyboard shortcuts**:

| Action | Default | What it does |
| --- | --- | --- |
| Play / pause | `Ctrl+Space` | Start or pause what is loaded |
| Next track | `Ctrl+→` | Skip forward in the queue |
| Previous track | `Ctrl+←` | Go back |
| Search | `Ctrl+K` (also `Ctrl+F`) | Open quick search |
| Library | `Ctrl+L` | Go to the Library tab |
| Queue | `Ctrl+U` | Show or hide what is up next |
| Now Playing | `Ctrl+P` | Open the full-screen player |

`Ctrl+F` is a fixed alias rather than a second binding: Linthra has always
answered it, so remapping search does not take it away, and nothing else can be
bound over it.

**One registry.** `lib/app/shortcuts/shortcut_action.dart` holds the actions,
their names, their descriptions and their defaults. The dispatcher installs it,
the settings card edits it, storage keys off it, and the help window planned in
#392 reads the same table — so a shortcut cannot be documented as one thing and
bound as another.

**No new playback logic.** Every action forwards to the `PlaybackController`,
router or overlay the buttons already use. The queue shortcut is the clearest
case: the frame answers it with the side column when the window is wide enough
and the app-level fallback opens the same sheet the phone uses otherwise, which
is the rule the now-playing bar's queue button already follows.

**Three surfaces answer the queue chord**, innermost first: an open queue
sheet closes itself, the wide Now Playing screen toggles its own pane rather
than stacking a sheet over it, and the navigation frame toggles the side column
when this window has one. Each declines when it is not the right host, and the
app-level fallback opens the sheet. Library is the odd one out: the frame
claims it whatever is drawn on top, clearing the overlay first, because a tab
switch nobody can see is not a tab switch.

**How the frame gets first refusal.** Through
[`ShortcutSurface`](../lib/app/shortcuts/shortcut_surface.dart), a tiny registry
the navigation frame binds itself into while it is mounted, rather than through
a nested `Actions` inside it. `Shortcuts` resolves an intent from wherever the
keyboard focus happens to sit, and focus is not something the frame controls:
leave a tab that had a page pushed inside it and focus lands on the scope
*above* the frame, at which point a nested `Actions` stops being found. The
symptoms were a modal queue sheet over a window that has a queue column, and
`Ctrl+L` flattening the Library stack it was meant to restore. A handler
returning `false` means "not mine right now" and hands the key back, so the
frame only describes the two cases it improves on — a visible queue column, and
switching to the Library branch with `goBranch` so the tab keeps its own stack —
and declines everywhere else, including under a route pushed over it.

**Media keys are not here.** `XF86AudioPlay` and friends reach Linthra through
MPRIS (#398), which works while the window is not focused. Binding one here
would be a second, worse path, so [`ShortcutBinding`](../lib/app/shortcuts/shortcut_binding.dart)
refuses a media key outright and says why.

**The typing guard is checked against the real thing.**
`test/app/shortcuts/text_editing_chords_test.dart` presses every bindable chord
into a real `TextField` with the platform set to Linux and holds
`conflictsWithTextEditing` to what the field actually did with it. A
hand-written list of "keys a field owns" goes stale, and a Flutter release that
added a chord to `DefaultTextEditingShortcuts` would otherwise turn one of the
bindings into a key that quietly eats an edit. One-directional: a chord the
field consumes must be one the guard stands down for, not the reverse, because
the guard is deliberately wider than the framework's map. (For the record,
Flutter's Linux map has no `Ctrl+U`, `Ctrl+D`, `Ctrl+H` or `Ctrl+W` — those are
readline conventions a GTK entry has and a Flutter text field does not — so
`Ctrl+U` is free to be the queue default.)

**Typing wins.** A shortcut stands down while the keyboard is in a text field
*if the field would have wanted that key* — the caret keys, Home/End,
Backspace/Delete, Space, the clipboard and undo letters, and any chord that
uses Alt on a printable key. That last one is AltGr: it is right Alt (and
Ctrl+Alt on some layouts), and AltGr plus an ordinary key is how a great many
layouts produce a character — `@` is AltGr+Q on a German keyboard. Flutter
reports "alt" without saying which side, so such a chord cannot be told apart
from somebody typing. It stands down inside a field rather than being refused
outright: refusing would take a whole modifier's worth of combinations away
from everyone to protect a case that only bites while typing. It is deliberately
not "no shortcuts while typing": `Ctrl+K` opens search from inside a search
field, which is where people press it. The rule is one predicate,
`conflictsWithTextEditing`, and the action is *disabled* rather than silently
swallowing the key, so the keystroke carries on to the field and the character
is typed.

**What cannot be bound**, each with a sentence saying what to do instead:

* a bare printable key, or Shift plus one — `Shift+K` is a capital K, and
  binding it app-wide would eat typing;
* `Escape` and `Tab`, which the app needs for closing things and moving around,
  and bare arrows, Enter, Space, Home/End, Page Up/Down, Backspace and Delete;
* a chord a focused control already answers: `Ctrl`/`Super` + `↑`/`↓` move a row
  in a reorderable list and `Shift+F10` opens a row's menu (#390). Those sit in
  a `Shortcuts` nearer the keyboard, so a global action bound to one would look
  bound and then do nothing whenever such a row had focus. Refusing is the
  better half of that trade: making the row controls stand aside instead would
  take keyboard reordering away from whoever bound a shortcut next to it. The
  refusal is for those chords *exactly* — `Ctrl+Shift+↑` and `Alt+↑` are free —
  which is why `ContextMenuRegion` now matches its two chords exactly too,
  instead of taking F10 with Shift and anything else held;
* `Alt+F4`, which never reaches the app: GTK turns it into the close request
  `linux/runner/window_lifecycle_channel.cc` answers by hiding or quitting.
  Only that one is listed — the rest of a desktop's own bindings are the user's
  to configure and vary by compositor, and a chord the desktop grabs simply
  does not arrive, the same way a media key does not;
* a media key, as above;
* a combination another action already has, including a fixed alias — the
  refusal names the action that has it.

Function keys are allowed bare: no text field produces one.

**Repeats fire once.** Every activator is built with `includeRepeats: false`, so
holding `Ctrl+→` skips one track rather than the whole queue.

**Nothing bare-key swallows a chord.** Widgets that answer a plain arrow — the
seek bar, and a grid's row wrap in `ListKeyboardNavigation` — stand aside when
Ctrl, Alt or Super is held (`shortcutModifierPressed`). Otherwise `Ctrl+→`
would have seeked *and* been reported handled, leaving the binding dead for as
long as that widget had focus.

**Nothing is bound before setup is finished.** The router gates onboarding on
its initial location alone, with no redirect guard, so the whole map stands
down until `onboardingControllerProvider` is true. A `Ctrl+L` out of onboarding
would otherwise have landed in an unconfigured library and sent the user back
to onboarding on the next launch.

**The queue sheet closes itself.** Not the shortcut, and not by popping the top
of the navigator: press Ctrl+U, then Ctrl+P, and the top is Now Playing. The
modal sheet claims the queue action through `ShortcutSurface` while it is up,
so it acts on its own route — pop while it is current, come out where it stands
when something was pushed over it (and let the fallback show a fresh one, since
the buried one is invisible), stand aside otherwise. Registering it with the
sheet rather than with the caller is what makes the chord able to close a sheet
the *mini-player button* opened: one queue, however it was put there.

**Reset is a rebinding.** "Reset to default" goes through the same
`setBinding`, so it is refused with the same wording when the default is no
longer free — remap Library off `Ctrl+L`, give `Ctrl+L` to Queue, and resetting
Library would otherwise have put two actions on one chord with the activator
map silently picking one. Reset-all needs no check: the shipped defaults are
distinct, and a test holds them to it.

**Persistence.** Only *overrides* are stored, one flat key per action in
`shared_preferences` (`keyboard_shortcut.play_pause`). An action the user never
touched has no row, so changing a default in a later release reaches everyone
who never disagreed with it and nobody who did; typing the original combination
back removes the override rather than pinning it. The duplicate check runs over
the composed table rather than one override at a time, because a *swap* (each
action moving onto the chord the other is leaving) is something the settings
screen legitimately writes, and checking one at a time would have undone both
halves of it on the next launch. Key ids from outside Flutter's
registry are reconstructed when they are Unicode-plane characters, so a chord
recorded on a non-US layout survives a restart; an id from a plane this build
has no meaning for is not guessed at. Writes are chained, so a reset-all and a
rebinding started on top of it reach storage one at a time in the order the
user asked for. An override that no longer
parses, that today's rules would refuse, or that would leave two actions on one
chord is dropped on read and the action keeps its default — a preferences file from a newer build, or one edited by
hand, degrades to stock behaviour rather than to a broken keyboard.

**Ctrl, not Cmd.** The desktop target is Linux, so the defaults are Ctrl. The
binding model carries a `meta` flag anyway, so a user can bind Super+key today
and a macOS build could default to Command without the storage format changing
under existing installs.

Tests: `test/app/shortcuts/` covers the binding rules and storage round trip,
the registry's own consistency, remapping/conflict/reset/persistence, and
dispatch — including a held key firing once, a text field keeping `Ctrl+→`, and
`Ctrl+K` still working inside one.
`test/features/settings/desktop/keyboard_shortcuts_section_test.dart` covers
recording a chord, being refused one, and the recorder staying escapable with
Tab and Escape.

## Window state

The window opens where you left it. `linux/runner/window_state_store.cc` writes
`$XDG_CONFIG_HOME/io.github.thezupzup.linthra/window-state` on shutdown and
reads it back before the window is shown, so a restored window is drawn at its
remembered size on the first frame rather than resizing in front of you.

Three things about it are worth knowing:

* **The size saved is the unmaximized one.** GTK 3 will not tell you that after
  the fact — `gtk_window_get_size()` on a maximized window returns the maximized
  size — so the store tracks the last size the window had while it was an
  ordinary window, and saves that alongside the maximized flag. Un-maximizing
  after a restart lands back where you left it.
* **Position is X11-only.** Wayland gives a client neither its own position nor
  a way to set one. Under Wayland the file holds a size and no position, and the
  compositor places the window, which is what Wayland users expect rather than
  something to work around.
* **A saved position is re-checked against the monitors that exist now.** Unplug
  the monitor a window was on and the position is dropped rather than restored
  off-screen; so is one whose title bar would land above the work area, where no
  mouse could reach it. The *size* survives either way — losing a monitor should
  not also lose the window's shape.

The rules behind all of that — what a saved geometry means, when it is too
damaged to trust, whether a position is still reachable — live in
[`native/linthra_desktop`](../native/linthra_desktop), which is pure C++ with no
GTK, no GDK and no filesystem in it. The runner links those sources directly and
does the toolkit half; the same sources build and test on their own, without a
display server or a second monitor to unplug, in
[`cpp-desktop-window.yml`](../.github/workflows/cpp-desktop-window.yml).

A damaged or missing file is never fatal: it falls back to the 1180×780 default,
clamped to the 420×600 minimum. Deleting the file resets the window.

It composes with [background mode](#closing-the-window): closing a window that
keeps playing *hides* it rather than destroying it, so the geometry stays
tracked and a launcher click gets the same window back at the same size. The
file is written when the application actually shuts down, whichever way it got
there.

## Guardrails

* `scripts/check_linux_runner.py` — the committed runner still matches the app's
  identity (`APPLICATION_ID` = Android's `applicationId`, `BINARY_NAME` =
  the package name, window title = `AppInfo.name`), it still makes the four
  desktop-identity calls below in the places where GTK honours them, it still
  sets the window's own caption ahead of the header-bar decision so it is set
  on both decoration paths, the window metrics are sane, the offline SQLite
  seam is wired, the folder-picker and window-lifecycle channels still agree
  with their Dart halves, the application is still registered single-instance,
  no string literal under `linux/` names a desktop environment or reads a
  desktop session variable beyond the one grandfathered exception, and nothing
  under `linux/` hardcodes an absolute host path.
  Tests: `test/tooling/check_linux_runner_test.py`.
* `test/tooling/desktop_environment_neutrality_test.dart` covers the Dart half
  of that last rule: no source under `lib/` reads a desktop session environment
  variable or compares against a desktop's name.
* `scripts/flatpak_launch_smoke.sh` — launches the packaged Flatpak twice and
  reads `WM_CLASS` and `_NET_WM_ICON` back off the real window each time, so a
  window that stops answering to the application id fails CI.
* `test/app/linux_startup_test.dart` — every provider `main()` reads before the
  first frame constructs on a Linux host, with no Android MethodChannel
  binding among them.
* `test/features/library/library_platform_bindings_test.dart` and
  `test/features/player/playback_platform_binding_test.dart` — each seam picks
  the Android implementation on Android and the desktop one on Linux.

`linux/CMakeLists.txt` and `linux/runner/my_application.cc` are listed as
`unmanaged_files` in `.metadata`, so `flutter migrate` leaves Linthra's edits
alone. If someone re-runs `flutter create --platforms=linux .` anyway, the
checker above is what catches the reverted title and the lost SQLite seam.

## Startup performance

How long Linthra takes to show you a usable library, and whether that changes,
is measured rather than guessed:

```bash
./tools/startup/run_startup_benchmark.sh
```

It launches the real app over an empty, a small (1,000-track) and a large
(20,000-track) synthetic catalog and records the time to the first frame that
actually shows the library: real track rows, or the onboarding prompt for an
empty one. No server, no network and no music collection are involved: the
catalogs are generated locally into real SQLite files in the production schema.

The verdict is a comparison against a baseline you record on the same machine,
never a fixed millisecond limit, and CI deliberately times nothing; it only
checks that the benchmark still runs and still produces a valid sample set.
[tools/startup/README.md](../tools/startup/README.md) covers what is and is not
measured, how to compare two runs, and why a debug number is not a release
number.

## Desktop identity

Everything Linthra installs on Linux is named `io.github.thezupzup.linthra`: the
desktop entry, the icon, the AppStream component, the Flatpak. The *running
window* only joins them if the runner says so, and each display server reads a
different thing, so `linux/runner/my_application.cc` sets all of them from
`APPLICATION_ID` (never from a literal):

| Call | Where | What reads it |
| --- | --- | --- |
| `g_set_prgname(APPLICATION_ID)` | `my_application_new()`, before `gtk_init()` | GTK 3 sends this as the Wayland `xdg_toplevel` app id, and as the instance half of X11's `WM_CLASS` |
| `gdk_set_program_class(APPLICATION_ID)` | `my_application_startup()`, **after** the chain-up | the class half of `WM_CLASS`. GDK's default is the program name with its first letter upper-cased, which is not the app id |
| `gtk_window_set_default_icon_name(APPLICATION_ID)` | same | GTK attaches the themed icon as `_NET_WM_ICON`; without it the window has no icon of its own |
| `g_set_application_name(AppInfo.name)` | same | `g_get_application_name()`, which GTK and portals show to the user |
| `gtk_window_set_title(kApplicationName)` | `my_application_activate()`, **before** the header-bar decision | X11's `_NET_WM_NAME` and Wayland's `xdg_toplevel.set_title`: the window's *caption*, which is not the header bar's title |

The two in `my_application_startup()` have to run after the chain-up to
`GtkApplication::startup`: that is what calls `gtk_init()`, and `gtk_init()`
resets GDK's program class unconditionally. Set earlier, they compile, run, and
are thrown away.

The last row is the one that is easy to miss (#458).
`gtk_header_bar_set_title()` draws a string inside the process;
`gtk_window_set_title()` is the only call that reaches the display server. The
Flutter template made the second call *only* on the branch where it had no
header bar, so on a header-bar desktop the window arrived with no caption at
all, and everything that reads a window title rather than resolving an
application id had nothing to show: task manager tooltips, window switchers,
overview labels, window rules matched on a caption, `wmctrl`/`xdotool`, and a
screen reader announcing the focused window. It is now set ahead of the
decoration choice, so it is set whichever way that choice goes.

`linux/packaging/io.github.thezupzup.linthra.desktop` declares the same X11 pair
as `StartupWMClass=`, so a shell matches the window to the entry exactly rather
than falling back to lower-casing whatever class it finds.

One more thing decides whether the icon appears at all: **the `<svg` root element
has to start within the first 256 bytes of `tool/branding/linthra_icon.svg`**.
An SVG has no magic number, so content sniffing looks for that literal string and
gives up after 256 bytes. Push it past that (a licence header, a `DOCTYPE`, a
descriptive comment between the XML declaration and the root tag) and gdk-pixbuf
refuses the file outright: GTK cannot load it as a themed icon, and every
launcher that resolves icons through that stack shows a generic one. The file
still parses, still validates, and still renders in a browser, which is why the
checker measures the offset. Put comments *inside* the root element.

## GNOME and KDE Plasma

Linux support is easy to tune to whichever desktop the person writing it runs.
Everything still builds, every test still passes, and the other desktop is the
one that breaks after release. So there is a repeatable pass covering both, run
on a real session before a Linux milestone:

**[docs/desktop-compatibility-matrix.md](./desktop-compatibility-matrix.md)**

It covers launch, window sizing and maximize/restore, light/dark appearance,
the file/folder portal, local music folder selection, notifications, MPRIS,
media keys, audio output and routing, secure credential storage, Flatpak
install and launch, Jellyfin/Navidrome/Plex configuration, basic playback, and
shutdown/relaunch. Wayland is the primary session on both desktops; the X11
rows are the handful where the display server genuinely changes something. It
also records the differences that belong to the compositor or the portal
backend and are therefore documented rather than worked around, and it carries
a copy-paste result sheet so a pass is written down rather than remembered.

Nothing in Linthra asks which desktop is running. Every Linux integration goes
through something both implement: portals for the file chooser and
notifications, MPRIS for media controls and media keys, the Secret Service for
credentials, freedesktop window properties for identity, the portal's
`color-scheme` for appearance. Two guardrails keep it that way, and both fail
the build on a new desktop check:

* `scripts/check_linux_runner.py` scans every string literal under `linux/` for
  a desktop session environment variable or a desktop name, with one
  grandfathered exception recorded in its
  `GRANDFATHERED_DESKTOP_NAME_CHECKS` table: the X11-only title bar decoration
  style, kept because GTK 3 implements no xdg-decoration protocol to defer to;
* `test/tooling/desktop_environment_neutrality_test.dart` does the same for
  `lib/`, where there is no exception at all.

Prose is exempt, and should be. Comments and docs name both desktops
constantly; it is a runtime branch on a desktop's name that is the problem.

## Suspend / resume (manual matrix)

System sleep and wake are only partly visible to Flutter: the embedder usually
delivers `AppLifecycleState.paused` → `resumed`, but audio devices (PulseAudio /
PipeWire, Bluetooth sinks) and the network often come back later than that
signal. Linthra therefore:

* arms recovery only on **`paused`** (not brief `inactive` dialogs);
* on Linux, after resume, waits a short backoff then **re-resolves and reloads
  the current track on the same engine** when playback was active across
  suspend — never a second player, so audio cannot duplicate;
* leaves a **user-paused** track paused;
* surfaces the existing error + Retry UI when recovery fails;
* does **not** enable this path on Android (screen-on must never auto-restart).

Automated coverage: `test/core/services/linux_suspend_resume_recovery_test.dart`
and the ActivePlaybackController lifecycle tests. Re-check on a real machine
before a Linux milestone release:

| Scenario | While… | Expect after wake |
| --- | --- | --- |
| Lid close / Sleep | Playing a **local** file | Same track/queue; audio returns near the prior position; no second stream |
| Lid close / Sleep | Playing a **remote** (Jellyfin / Navidrome / Plex) stream | Fresh stream URL; same logical track/queue; Reconnecting… then playing, or error + Retry if the server is still down |
| Lid close / Sleep | **Paused** | Still paused; pressing play resumes the same track |
| Sleep with **Bluetooth** headphones offline | Playing | Recoverable error or success once the sink returns; never hung forever |
| Sleep with **network** offline | Playing remote | Bounded recovery; Retry works when connectivity returns |
| Minimize only (no sleep) | Playing | App stays responsive; no crash; ideally continues without a full reload |
| Repeat sleep/wake **3×** | Playing | Still one coherent queue/position; no growing listener/service leak; UI stays usable |

## Closing the window

By default, closing the window quits Linthra, which is what it has always done.
Settings → Music & playback → **Desktop window** offers the other choice:
keep playing in the background, where a close hides the window and leaves
playback and the desktop media controls running.

The decision is split across the two halves on purpose:

* **Dart decides.** `DesktopClosePolicy` combines the stored preference with
  the live playback state, and `DesktopWindowLifecycleService` pushes the one
  resulting boolean to the runner whenever either changes.
* **The runner applies.** A GTK `delete-event` has to be answered
  synchronously, so `linux/runner/window_lifecycle_channel.cc` cannot ask
  anything: it already holds the answer, and either hides the window or lets
  GTK destroy it.

What that buys, in the order the requirements ask for it:

* **No hidden zombie process.** Background mode only takes effect while audio
  is playing (or loading, buffering, reconnecting). Close it while paused,
  stopped or idle and Linthra quits, whatever the preference says.
* **Nothing extra is started for it.** Hiding the window starts no background
  service and no second process: it is the same running app with its window
  away, so the audio engine, the queue and the MPRIS export carry on and the
  window simply stops drawing. Linux has no foreground-service concept to hold
  the way Android does.
* **A hidden Linthra ends itself.** When the queue runs out, the app quits on
  its own rather than sitting invisibly in the process list. A *pause* keeps it
  alive, because with no window on screen a shell's media widget is the only
  way back to playing.
* **A clear way to fully quit.** "Quit Linthra now" sits in the same settings
  card, and MPRIS `Quit` does the same thing from the desktop's media controls.
  Both run the app's graceful shutdown (stop playback, release the audio
  engine, give back the MPRIS bus name, close the database) *before* the
  process ends, rather than leaving it to whatever time the engine gets on the
  way down.
* **No duplicate instance.** The runner is single-instance, so launching
  Linthra while it is already running (from the launcher, a terminal, or a
  desktop file) reaches the running process as an activation and presents the
  window it already has, hidden or not. Two processes would mean two audio
  engines, two MPRIS names and two connections to the same SQLite catalog.
  `scripts/check_linux_runner.py` fails if the runner goes back to
  `G_APPLICATION_NON_UNIQUE`.

One deliberate interaction with [suspend / resume](#suspend--resume-manual-matrix):
while the window is hidden, Linthra does **not** arm the post-suspend reload.
A hide looks exactly like a system suspend from the lifecycle observer's side,
and reloading a track the listener never stopped would be an audible skip. The
trade is that a real machine suspend taken while the window is hidden is not
recovered from either; it is recovered the next time the window comes back.

Automated coverage: `test/core/lifecycle/desktop_close_policy_test.dart`,
`test/core/services/desktop_window_lifecycle_service_test.dart`,
`test/core/services/method_channel_linux_window_test.dart`,
`test/features/settings/desktop/desktop_window_section_test.dart`, and the
runner contract in `test/tooling/check_linux_runner_test.py`. What only a real
desktop can answer, to re-check before a Linux milestone release:

| Scenario | Setting | Expect |
| --- | --- | --- |
| Close the window while a track plays | Keep playing | Window disappears, audio continues, media controls still work |
| Click the launcher again while hidden | Keep playing | The same window comes back; one process, one entry in the media controls |
| Raise from the shell's media widget | Keep playing | Same as above |
| Let the queue finish while hidden | Keep playing | Linthra exits on its own; the MPRIS entry disappears from the shell |
| Pause from the media widget while hidden, then play | Keep playing | Still there, resumes the same track |
| Close the window while paused | Keep playing | Linthra quits; nothing is left running |
| Close the window while a track plays | Quit | Linthra quits, audio stops |
| Quit from the media widget, or "Quit Linthra now" | Either | Playback stops, the window goes, the MPRIS name is released |
| Reopen after any quit | Either | Normal cold start; the crash-safe session restores paused, as it always did |

## Track change notifications

Off by default. Settings → Music & playback → **Desktop notifications** turns
on a short notification when the song changes: the title, the catalog's
"Artist • Album" subtitle, and the cover when there is a safe one to hand over.

It is off by default because a desktop shell already draws a now-playing card
from Linthra's MPRIS session. A toast per track is a useful addition for
someone who wants it and an unasked-for interruption otherwise, so it is the
listener's choice, and the switch turns it off completely rather than making it
quieter.

### What counts as a track change

`TrackChangeNotifier` watches the same `PlaybackState` stream MPRIS and the
recent-played recorder read, and is a pure observer of it: it never touches the
queue, the controller or the audio engine. The stream carries a state several
times a second, and almost none of them are news, so three rules reduce it to
real transitions:

* **Identity.** The track's logical identity has to differ from the last one
  announced. Position ticks, a pause, a resume, a seek, a volume change, a
  mid-stream reconnect and a queue rebuild that re-creates the same song all
  say nothing, and neither does repeat-one starting the same song again,
  because that is not a new song.
* **Something is actually playing.** A queue restored paused at launch, a track
  loaded but not started, and a load that errored are all "nothing is playing".
  Announcing one would be a claim Linthra cannot back.
* **At most one per five seconds.** Holding *next* down through an album must
  not put a notification per track on the bus. A burst is coalesced rather than
  dropped: the newest track replaces whatever was waiting, one timer covers the
  whole burst, and the track the listener actually landed on is the one
  announced. Ordinary listening never meets this limit at all.

  A waiting announcement is only made if it is still true when the window
  closes. Skip to a track and back inside those five seconds, or pause inside
  them, and it is dropped rather than naming a track the listener has left.
  The window is measured on a monotonic clock, so a time correction (NTP, a
  manual change) cannot make the gap since the last notification negative and
  silence the next one for the length of the correction.

Turning the preference off is read live, so it silences the next track change
immediately, including one already waiting out that window.

### What it says, and what it never says

`nowPlayingNotification` is the whole of what Linthra is willing to tell a
notification daemon, and it is a pure function so that the rule is in one
readable place rather than inside a D-Bus call. It sends the title and the
artist/album subtitle. It never sends:

* the track's URI: for a remote track that is an authenticated stream URL, for
  a local one the listener's own file path;
* the track or album id, or anything naming the server it came from;
* a cover *reference*, or any URL at all.

Artwork follows the same rule MPRIS publishes `mpris:artUrl` under, narrowed
for a consumer that opens files rather than fetching URLs:

* a `file:` cover passes through. Every `file:` cover in the catalog is a copy
  Linthra wrote into its own artwork cache, under the application cache
  directory, which is the same path inside the Flatpak and outside it, so the
  daemon can actually open it;
* an app-internal reference (`subsonic-cover:<id>`, `plex-thumb:<path>`) is
  published only as the local copy the media-artwork cache has *already*
  fetched. Nothing is fetched on the track change itself;
* an `http(s)` cover is dropped: a daemon does not fetch a URL for an image,
  and a cover URL is the shape a credentialed one would arrive in;
* a `content:` cover is dropped: that is Android's FileProvider form, and
  nothing on a Linux desktop can open it.

A track with no title at all reads as "Unknown track", never as its path.

One escaping detail, because the metadata comes from a server the listener
configured rather than from Linthra: the freedesktop spec's `body` is
markup-capable, so the subtitle is escaped for that route. Without it an
ordinary `&` in a name is invalid markup a daemon may drop, and a server could
put formatting or a link in an artist name and have the desktop render it. The
portal's `body` is literal text by contract (markup lives behind a separate
key it is never sent), so it takes the text as it is.

### How it reaches the desktop

A desktop notification is a D-Bus method call, and that is what Linthra makes,
through the same `dbus` package MPRIS already uses, so there is no new
dependency, no native code, and **no subprocess**. Shelling out to
`notify-send` would mean a music player spawning a binary off `PATH` with
strings built from track metadata, and it does not exist inside the Flatpak
anyway.

`DBusDesktopNotifier` tries two routes and remembers which one answered:

1. **`org.freedesktop.portal.Notification`** on the desktop portal. First,
   because it is the only route a sandboxed Linthra has: the Flatpak asks for
   no `--talk-name` at all (`scripts/check_flatpak_permissions.py` refuses
   every spelling of one), and the portal is available to every Flatpak with no
   finish-arg. See [docs/flatpak-permissions.md](./flatpak-permissions.md).
2. **`org.freedesktop.Notifications`**, the spec interface every notification
   daemon implements, for a host that has no portal running: a bare window
   manager with `dunst`, say.

Both keep one notification rather than a pile: the portal route reuses a fixed
id, which is how the portal replaces a notification, and the spec route passes
the previous notification's id as `replaces_id`. The spec route also asks for
low urgency and marks the notification transient, so a track change belongs on
screen for a moment rather than in the shell's history for the evening.

Artwork goes out in whichever form the route can take safely: an `image-path`
hint on the spec route, and on the portal route a serialized `bytes` icon,
only when the running portal reports interface version 2 or newer, which is
where that icon form was added, and bounded to 512 KiB so a cover cannot
become a large transfer on every track change.

Failure is silent and total: a missing daemon, a refused call, a bus that went
away, a cover evicted between being cached and being sent. Every delivery is
guarded and never awaited by playback, so the worst case is a notification that
did not appear. Each call is also given a five-second deadline, because nothing
awaits it. A deadline alone is not enough there: Dart's `Future.timeout` ends
the wait, not the D-Bus call underneath it, so a timeout also drops the
connection, which is what abandons the outstanding call and stops it landing a
stale notification later. The next track change opens a fresh one.

Automated coverage:
`test/core/services/notifications/track_change_notifier_test.dart`,
`test/core/services/notifications/now_playing_notification_test.dart`,
`test/core/services/notifications/dbus_desktop_notifier_test.dart`,
`test/core/services/notifications/platform_desktop_notifier_test.dart`,
`test/features/settings/desktop/desktop_notifications_section_test.dart`, and
`test/data/repositories/shared_preferences_desktop_notification_preferences_test.dart`.
What only a real desktop can answer, to re-check before a Linux milestone
release:

| Scenario | Expect |
| --- | --- |
| Turn the switch on, then let a track end into the next one | One notification, with title, artist and cover |
| Pause, resume, seek, change the volume | No notification |
| Hold *next* through several tracks | One notification, for the track you land on |
| Turn the switch off, then change track | Nothing at all |
| Play a local file with embedded art, and a server track whose cover is cached | Cover shown in both |
| Play a server track whose cover has not been fetched yet | Notification without a cover, never a placeholder or a URL |
| Same, in the Flatpak | Identical behaviour; `flatpak info --show-permissions` unchanged |
| Kill the notification daemon, then change track | Playback unaffected, no error anywhere in the app |

## Crash-safe playback restore

On Linux, Linthra persists a small **logical** playback session while a track is
queued — provider-namespaced track ids (`jellyfin:…`), local paths, shuffle/
repeat modes, and position. It never writes authenticated stream URLs or
provider tokens. After an unexpected process exit, the next launch restores that
queue as **paused** (never autoplay); pressing play re-resolves remote tracks
through the normal signed-in provider path. Missing local files, signed-out
providers, and wrong-version/corrupt records drop only the invalid rows (or the
whole session) and never block startup.

Automated coverage: `test/core/models/persisted_playback_session_test.dart`,
`test/data/repositories/shared_preferences_playback_session_store_test.dart`,
`test/core/services/playback_session_persistence_test.dart`.

## Installing from GitHub Releases (`.flatpak`)

Every stable Release carries a standalone Flatpak bundle,
`Linthra-<tag>-x86_64.flatpak` (e.g. `Linthra-v0.2.7-x86_64.flatpak`). It is
the easiest way to install Linthra on Linux today: one file, no tar extraction,
no `.desktop` file to write by hand, and none of the
[required packages](#required-packages) below — the sandbox brings its own
GTK stack and its own libmpv.

Linthra is **not on Flathub yet** ([#456](https://github.com/TheZupZup/Linthra/issues/456)
tracks that). Until it is, this bundle is the recommended GitHub-Releases
install; the [native tarball](#release-tarball) stays available for anyone who
would rather run the plain build.

You need Flatpak itself installed, and the GNOME runtime the bundle declares.
Most desktop distributions ship Flatpak; if yours does not, [flatpak.org's
setup guide](https://flatpak.org/setup/) covers it. The bundle names Flathub as
where its runtime comes from, so the install can fetch `org.gnome.Platform//51`
if the machine does not already have it.

**Graphical install.** On a desktop whose software centre handles Flatpak
bundles (GNOME Software and KDE Discover both do, when the Flatpak backend is
installed), opening the downloaded file offers to install it. This is not
universal — plenty of Linux desktops have no such association, and a file
manager may simply not know what to do with a `.flatpak`. If nothing happens
when you open it, use the CLI.

**CLI install.**

```bash
flatpak install --user Linthra-v0.2.7-x86_64.flatpak
```

Then launch it from the application launcher, or:

```bash
flatpak run io.github.thezupzup.linthra
```

To remove it:

```bash
flatpak uninstall --user io.github.thezupzup.linthra
```

Uninstalling removes the application and its sandboxed data. It does not touch
your music: Linthra never has host filesystem access, and reaches local
libraries only through the file-chooser portal, so the files it played are
outside anything the package owns. Flatpak keeps per-app data under
`~/.var/app/io.github.thezupzup.linthra/`; `flatpak uninstall --delete-data`
removes that too.

### Verifying what you downloaded

Every stable publication records each asset's SHA-256 in its workflow run
summary, the bundle included, taken from the published file. Compare it with:

```bash
sha256sum Linthra-v0.2.7-x86_64.flatpak
```

See [release-artifact-verification.md](./release-artifact-verification.md) for
what that record is and what it is worth.

### Manual Flatpak smoke checklist

CI builds the bundle on a clean runner, installs it, launches it under Xvfb and
checks the packaged window's identity and icon. What it cannot do is look at a
real GNOME or KDE session, so a release is not signed off on Linux until
someone runs this on an actual desktop. It takes a few minutes.

Use a machine (or a fresh user account) with no existing Linthra
installation, and a few local music files you own. **Never use production or
private server credentials for this** — a local folder, or a throwaway test
server, is enough.

1. Download `Linthra-<tag>-x86_64.flatpak` from the Release.
2. Install it (`flatpak install --user <file>`, or through the software centre
   if your desktop offers to).
3. Open the application launcher and confirm **Linthra** appears there.
4. Confirm the entry shows the correct name and the Linthra icon — not a
   generic placeholder.
5. Launch it from the launcher.
6. Confirm it reaches a usable first frame (the library shell, not a blank
   window or an error).
7. Confirm the local audio backend initializes: add a music folder through the
   file chooser and confirm tracks appear.
8. Play a track. Confirm audio actually comes out, and that pause/seek work.
9. Close the window and relaunch from the launcher. Confirm it reopens and
   groups with the same launcher entry rather than appearing as a second one.
10. Uninstall (`flatpak uninstall --user io.github.thezupzup.linthra`).
11. Confirm the music files you added are still on disk, untouched.

If step 3 or 4 fails, the export half of the package is wrong (desktop entry or
icons). If step 7 or 8 fails, the packaged audio runtime is the place to look:
CI already walks that lifecycle inside the sandbox
([flatpak-audio-smoke.md](./flatpak-audio-smoke.md)), so a failure here that CI
did not catch is worth reporting with the details, and
[flatpak-development.md](./flatpak-development.md) has the commands for
inspecting the sandbox by hand.

## Release tarball

The native alternative to the [Flatpak bundle](#installing-from-github-releases-flatpak)
above, for anyone who already has the runtime dependencies installed.

Every official release gets `Linthra-<tag>-linux-x64.tar.gz` attached to its
GitHub Release automatically — e.g. `Linthra-v0.1.15-linux-x64.tar.gz` for
tag `v0.1.15`. This isn't wired to a tag push or a Release-publish event
(Linthra's release automation creates both using its own `GITHUB_TOKEN`,
and GitHub generally doesn't start new workflow runs from `GITHUB_TOKEN`-
authored events); instead `publish-stable-release.yml` (for stable releases)
and `android-release-build.yml` (for a directly-pushed alpha/beta/rc tag)
explicitly dispatch `linux-desktop-build.yml` at the exact release tag once
the Release exists. The archive is exactly `flutter build linux --release`'s
output (`build/linux/x64/release/bundle/`) at that tag, tarred with the
bundle contents (`linthra`, `lib/`, `data/`, …) at the archive root:

```bash
tar -xzf Linthra-v0.1.15-linux-x64.tar.gz
./Linthra-v0.1.15-linux-x64/linthra
```

**This is the native Linux build, not a self-contained package.** It still
needs the runtime libraries in [Required packages](#required-packages) —
libmpv and GTK 3 in particular — already installed on the machine running it,
and a Secret Service provider for [secure storage](#secure-storage). It is
**not** distro-independent. The
[`.flatpak` bundle](#installing-from-github-releases-flatpak) is the
self-contained, sandboxed one; this tarball is a plain native build, built by a
different workflow, with no bearing on the Flatpak's design.

See [docs/release-process.md §4a](./release-process.md#4a-linux-release-tarball-dispatched-alongside-the-android-build)
for exactly how the CI job builds and attaches it.

## Where this is going

The Linux distribution target is **Flathub**. The
[`.flatpak` bundle on GitHub Releases](#installing-from-github-releases-flatpak)
is what Linux users install until Linthra is accepted there
([#456](https://github.com/TheZupZup/Linthra/issues/456)), not the destination.

That packaging is now underway in #376 and lives outside this page: the
committed manifest is in [`flatpak/`](../flatpak/README.md) and the contributor
workflow for building, installing and debugging it on Fedora Atomic is
[flatpak-development.md](./flatpak-development.md). It builds, installs and
launches with working audio, and installs the desktop entry
(`linux/packaging/io.github.thezupzup.linthra.desktop`, shared with any future
native package rather than Flatpak-only) together with Linthra's icon under
`share/icons/hicolor/` (the scalable SVG launchers resolve, plus the fixed-size
PNGs GTK needs for the window's own `_NET_WM_ICON`) and AppStream metainfo
under
`linux/packaging/io.github.thezupzup.linthra.metainfo.xml`; networking is
granted with one narrow permission, secure storage needs none (it goes through
the desktop's Secret portal), and the remaining filesystem-permission audit is
still an open sub-issue.
None of it changes the native build on this page.

Decisions already taken with that destination in mind:

* one reverse-DNS application id shared with Android, stable and
  Flathub-shaped (`io.github.thezupzup.linthra`);
* no build-time dependency on host filesystem paths (enforced by the checker);
* no runtime downloading of anything that belongs in the build;
* the SQLite escape hatch above, so a network-isolated build is already
  possible;
* every platform integration behind an interface, so a sandboxed portal-based
  implementation can be slotted in without touching feature code.
