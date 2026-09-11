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

| Piece | File |
| --- | --- |
| The snapshot + renderer | `lib/core/diagnostics/linux_playback_diagnostics.dart` |
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
| Narrow the window to its 420 px minimum, or raise the desktop's text scale | The card's two actions stack instead of sharing a row, and the labels stay readable. |

## Remaining Linux limitations

| Area | State | Why |
| --- | --- | --- |
| **Audio playback** | Supported | media_kit/libmpv through `LinuxPlaybackController`; local files and resolved Jellyfin, Navidrome/Subsonic, and Plex HTTP(S) streams share one backend. |
| **Suspend / resume** | Supported (app side); real device/sink timing varies | Lifecycle `paused`→`resumed` arms a bounded Linux-only reload of an actively playing track after a short backoff ([issue #466](https://github.com/TheZupZup/Linthra/issues/466)). See [Suspend / resume (manual matrix)](#suspend--resume-manual-matrix). |
| **Light/Dark/System theme** | Supported (app side); the native brightness bridge itself is Flutter's, not independently verified here | Settings → Appearance's System/Light/Dark choice ([issue #459](https://github.com/TheZupZup/Linthra/issues/459)) is the same shared `ThemeModePreference`/`ThemeModeController` Android uses, mapped onto `MaterialApp`'s own `themeMode` — no `gsettings`/D-Bus/GNOME/KDE-specific code in Linthra itself, and no separate Linux theme path (`test/app/theme_mode_test.dart` proves that). *Supplying* System's brightness on Linux is Flutter's GTK embedder (via the XDG desktop portal or a GNOME GSettings fallback); that native bridge is outside Linthra's code and isn't exercised by `flutter test`, which runs on the Dart VM and injects brightness straight into Flutter's test `PlatformDispatcher`. Reproducing the real bridge deterministically in CI would need a running portal daemon or GNOME schemas — exactly the DE-specific setup this app avoids adding — so it stays untested here and is a known gap, not a claimed guarantee. |
| Media session / MPRIS | Supported | `PlatformMediaSessionBinding` routes Linux to `MprisMediaSessionBinding`, which exports `/org/mpris/MediaPlayer2` and owns `org.mpris.MediaPlayer2.linthra` ([issue #397](https://github.com/TheZupZup/Linthra/issues/397)). Shells get PlaybackStatus, Metadata, Position and the transport methods; media keys work through the same interface. `Volume` is read/write, so a shell's own volume slider drives Linthra's level (and reads zero while muted); `Rate` stays honestly read-only. `Raise` and `Quit` are answered too, so a listener whose window is hidden by background mode can bring Linthra back or shut it down from the shell's media widget (#401). `audio_service` is still never initialised on Linux — it stays the Android delegate. A machine with no session bus simply gets no desktop controls. |
| Close-window behaviour | Supported | Settings → Music & playback → Desktop window chooses between quitting and keeping playback running ([issue #401](https://github.com/TheZupZup/Linthra/issues/401)). The runner answers the close, Dart decides what the answer should be, and background mode only ever starts while audio is actually playing. See [Closing the window](#closing-the-window). |
| Android Auto | Android-only, by design | It is an Android platform integration, not a Linthra feature. |
| Media notification + `POST_NOTIFICATIONS` | Android-only, by design | There is no equivalent gate on Linux; desktop controls come from MPRIS instead. Standalone track-change notifications are [issue #400](https://github.com/TheZupZup/Linthra/issues/400). |
| Android audio focus | Android-only, by design | `JustAudioPlaybackController` already scopes its focus handling to Android/iOS. |
| SAF (`content://` folders) | Android-only, by design | Linux picks a real filesystem path. The scanner's desktop path is the one that runs. |
| Folder chooser | Supported | Linthra's own runner channel (`linux/runner/folder_picker_channel.cc`) opens `GtkFileChooserNative`: the ordinary GTK dialog natively, and the xdg-desktop-portal chooser inside the Flatpak, where `file_picker`'s `zenity`/`kdialog` do not exist ([issue #438](https://github.com/TheZupZup/Linthra/issues/438)). `scripts/check_linux_runner.py` holds the runner's channel name to the Dart side's. |
| Multiple music folders | Supported | Settings → Local music takes several folders and scans them as one library ([issue #412](https://github.com/TheZupZup/Linthra/issues/412)). A folder selected inside another one is walked once, removing a folder removes only its tracks, and an existing single-folder selection carries over as the first folder. Android keeps its single SAF/MediaStore selection. |
| Lost folder access | Supported | A selected folder that stops resolving (unmounted drive, deleted folder, revoked portal document) is reported as a recoverable "select it again" state on that folder's row of the Local music card, and the indexed catalog is left alone rather than replaced with an empty scan. With several folders, the readable ones still refresh while the unreachable one keeps the tracks it already contributed. |
| Local tag reading | Supported | `FilesystemLocalMetadataReader` reads title, artist, album artist, album, track number and duration from ID3, Vorbis comments, MP4 atoms, APEv2 and RIFF INFO through `audio_metadata_reader` ([issue #407](https://github.com/TheZupZup/Linthra/issues/407)). An unreadable or untagged file still appears, from its filename. Android is deliberately unchanged: its tags come from the native SAF walk. |
| Local embedded artwork | Unsupported | Tags are read without pulling cover images out of every file during a scan. Extracting and caching embedded art on desktop is [issue #408](https://github.com/TheZupZup/Linthra/issues/408); tracks keep the placeholder until then. |
| **Audio output device** | Supported | Settings → Music & playback → Audio output lists libmpv's `audio-device-list` and routes playback with `audio-device` ([issue #402](https://github.com/TheZupZup/Linthra/issues/402)). A saved device is re-applied at launch, and one that is no longer present falls back to the system default. See [Audio output device](#audio-output-device). |
| **Device hotplug** | Supported | A headset, Bluetooth speaker or HDMI sink appearing or disappearing mid-playback is recovered without restarting the track or creating a second player, and a chosen device that comes back takes playback back ([issue #403](https://github.com/thezupzup/linthra/issues/403)). If even the system default is refused, the card says so and offers a retry. See [Device hotplug](#device-hotplug). |
| **Playback diagnostics** | Supported | Settings → Diagnostics & support → Linux playback builds a copyable report of the backend, libmpv, the selected output subsystem and recent failure kinds ([issue #406](https://github.com/thezupzup/linthra/issues/406)). Safe by construction: no field can hold a URL, token, header, path, device name or raw error. See [Playback diagnostics](#playback-diagnostics). |
| Chromecast | Android/iOS only | Already gated in `cast_providers.dart`; Linux keeps the honest "cast unavailable" service. |
| Share sheet, launcher-icon switching | Android-only, by design | No desktop equivalent; the UI simply omits them. |
| Volume control | Supported | A mute and a slider on Now Playing and the wide mini-player bar, plus MPRIS `Volume`, driven through `PlaybackController` and remembered across launches ([issue #394](https://github.com/TheZupZup/Linthra/issues/394)). See [Volume](#volume). |
| Desktop layout | Supported | The shell swaps its bottom bar for a navigation rail at 900 px, and feature screens adapt on the width they are given — including a third pane for the Library grids and for Now Playing's queue. See [How the desktop layout adapts](#how-the-desktop-layout-adapts). |
| Window geometry | Supported | Size and maximized state survive a restart; position too, on X11. A saved position is re-checked against the monitors attached now. See [Window state](#window-state). |
| Content density | Supported | Compact by default, switchable to Comfortable in Settings → Appearance and remembered across restarts ([issue #395](https://github.com/thezupzup/linthra/issues/395)). Both are Material `VisualDensity` values, so the choice reaches every list row, grid and control at once. Touch builds are unaffected. See [Density (Compact / Comfortable)](#density-compact--comfortable). |
| Pointer affordances | Supported | Compact content density, visible hover feedback, right-click context menus with a keyboard equivalent, and Ctrl/Shift multi-select in track lists — all keyed on the input rather than the window width. See [Pointer, not width](#pointer-not-width). |
| Keyboard shortcuts | Partial | Quick search is bound to **Ctrl+K** / **Ctrl+F** ([issue #393](https://github.com/TheZupZup/Linthra/issues/393)) — see [Quick search](#quick-search-ctrlk). The volume control takes the wheel and arrow keys when focused; global transport and volume shortcuts are still later work in #376. |

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
* **The now-playing bar** — on a desktop host the progress line along its top
  edge is a seek control, not a readout: the same `PlaybackProgressBar` the full
  player uses, at its compact density and without the time caption. Width alone
  does not promote it — a tablet in landscape is as wide as a desktop window and
  still driven by a thumb.

Both breakpoints in the app agree by construction: the shell swaps its bottom
bar for the navigation rail at 900 px of window, and a feature screen inside it
only reaches `expanded` once the space left over is 1000 px wide.

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

### Quick search (Ctrl+K)

**Ctrl+K** (or **Ctrl+F**) opens a quick-search overlay over whatever is on
screen: one box across songs, albums, artists and playlists, grouped and fully
keyboard-driven (↑/↓ to move, Enter to open, Esc to close). The screen
underneath keeps its state — it is a dialog on the root navigator, not a
navigation — and opening a result goes through the app's existing routes and
playback actions.

Like the layout, it is **not** gated on `HostPlatform`: the binding
([`quick_search_shortcuts.dart`](../lib/app/quick_search_shortcuts.dart)) wraps
the router, above every route, and can only fire when a real keyboard sends the
chord — so a phone is unaffected while an Android tablet with a keyboard case
gets it for free. What it searches and how it ranks is documented in
[library.md](./library.md#quick-search-ctrlk).

Tests: `test/shared/layout/adaptive_layout_test.dart`,
`test/features/library/album_grid_test.dart`,
`test/features/library/artist_grid_test.dart`,
`test/features/library/detail_desktop_layout_test.dart`,
`test/features/player/player_desktop_layout_test.dart` — each covers the phone
width alongside 1280, 1920, 2560 and ultrawide, so a change that only looks
right on one monitor fails.

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
  desktop-identity calls below in the places where GTK honours them, the window
  metrics are sane, the offline SQLite seam is wired, the folder-picker and
  window-lifecycle channels still agree with their Dart halves, the application
  is still registered single-instance, and nothing under `linux/` hardcodes an
  absolute host path.
  Tests: `test/tooling/check_linux_runner_test.py`.
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

The two in `my_application_startup()` have to run after the chain-up to
`GtkApplication::startup`: that is what calls `gtk_init()`, and `gtk_init()`
resets GDK's program class unconditionally. Set earlier, they compile, run, and
are thrown away.

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

## Release tarball

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
**not** distro-independent. The eventual [Flatpak](#where-this-is-going) is
the self-contained, sandboxed distribution target; this tarball is a plain
native build for anyone who already has the runtime dependencies on hand, and
it is separate work with no bearing on the Flatpak's design.

See [docs/release-process.md §4a](./release-process.md#4a-linux-release-tarball-dispatched-alongside-the-android-build)
for exactly how the CI job builds and attaches it.

## Where this is going

The Linux distribution target is **Flathub**. A locally installable Flatpak on
Fedora Kinoite is a validation step on the way, not the destination.

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
