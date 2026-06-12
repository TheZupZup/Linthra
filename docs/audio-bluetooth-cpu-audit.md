# Audit — Bluetooth, Bluetooth LE / modern-Android compatibility, and CPU efficiency

This is the **audit report** for the phase that follows the Chromecast paused-poll
battery fix (PR #142). It is a read-only review of what the code does today, with
the evidence (file references) behind each finding, so the small follow-up changes
in this PR are reviewable against a clear baseline.

**Scope:** Bluetooth media controls + metadata, Bluetooth LE / modern-Android
compatibility, and CPU efficiency across the playback states. It deliberately does
**not** refactor the playback stack, change the UI, or add telemetry.

> **Bottom line.** Linthra drives Bluetooth (classic and LE/LE-audio), the lock
> screen, the notification, car audio, and Android Auto entirely through the
> **standard Android `MediaSession` + audio-focus** path provided by
> `audio_service` + `just_audio` — there is **no custom Bluetooth code** anywhere
> in the app. Pause-on-disconnect ("becoming noisy"), audio-focus ducking, and
> media routing are handled by `just_audio`'s defaults. The CPU/wake-up profile is
> already tight: the only periodic timers are the (now play-state-gated) cast poll,
> a coalesced ~4 Hz position flush that stops when paused, and a cast position
> ticker that runs only while casting *and* playing. **No correctness or efficiency
> bug was found that warrants a runtime code change.** The deliverables here are
> this report, regression tests that lock in the Bluetooth-facing invariants, and a
> manual test checklist for the device behaviour CI can't exercise.

---

## How this was audited

- Read the whole media/playback path: `lib/core/services/linthra_audio_handler.dart`
  (the only file that imports `audio_service`), `just_audio_playback_controller.dart`,
  `active_playback_controller.dart`, `local_playback_controller.dart`, and the
  player providers in `lib/features/player/player_providers.dart`.
- Swept every Dart source for timers, polling, continuous animations, platform
  channels, and Bluetooth APIs (`Timer`, `Stream.periodic`, `AnimationController`,
  `.repeat(`, `MethodChannel`, `Bluetooth`, `becomingNoisy`, `AudioSession`, …).
- Read the Android side: `AndroidManifest.xml`, `MainActivity.kt`,
  `SafDocumentScanner.kt`.
- Confirmed `just_audio` 0.9.46 default behaviour against the published package
  docs (interruptions, becoming-noisy, audio attributes).
- Ran the existing suite as a baseline (`flutter test`), then added the regression
  tests described below.

Versions in `pubspec.lock`: `just_audio 0.9.46`, `audio_service 0.18.18`,
`audio_session 0.1.25` (transitive).

---

## 1. Bluetooth media controls

**Verdict: correct, and now covered by regression tests.**

All Bluetooth transport — a headset's play/pause/next/previous/stop, a
steering-wheel button, a car head unit, the lock screen, and the Android media
notification — arrives as the **same** `MediaSession` callbacks. `audio_service`
routes them to `LinthraAudioHandler`, which forwards to the single
`PlaybackController`. There is no separate Bluetooth path.

| Control | Path | Status |
| --- | --- | --- |
| Play / Pause | `LinthraAudioHandler.play/pause` → controller | ✅ tested |
| Next / Previous | `skipToNext/skipToPrevious` → controller | ✅ tested |
| Stop | `stop()` → controller + `super.stop()` | ✅ tested |
| Seek | `seek()` → controller | ✅ tested |
| Skip-to-queue-item (car Up Next) | `skipToQueueItem` → history/up-next jump | ✅ tested |
| Shuffle / Repeat | `setShuffleMode/setRepeatMode` → controller | ✅ tested |

- **Capabilities advertised to the device.** `_playbackStateFor`
  (`linthra_audio_handler.dart:329`) advertises `seek`, `skipToNext`,
  `skipToPrevious`, `skipToQueueItem`, `setShuffleMode`, `setRepeatMode` in
  `systemActions` **steadily** — not toggled at queue edges — so a head unit /
  Bluetooth device that caches the capability set when it connects keeps its
  Next/Previous and queue-row buttons live. The **visible** notification /
  lock-screen buttons are still gated (`_controlsFor`, `:411`): `skipToPrevious`
  only when a previous track exists, `skipToNext` only when one is queued, so no
  dead button is shown. This invariant is now locked by a test (see §5).
- **Lock screen / notification.** Driven by the same `playbackState`/`mediaItem`
  the handler publishes; the notification is configured ongoing while playing
  (`androidNotificationOngoing: true`, `androidStopForegroundOnPause: true` at
  `:482`). `MediaButtonReceiver` in the manifest (`:95`) handles hardware/Bluetooth
  `MEDIA_BUTTON` intents.

### Metadata sent to Bluetooth / lock screen / car

`_trackMediaItem` (`linthra_audio_handler.dart:311`) maps each `Track` onto a
`MediaItem`:

| Field | Source | Notes |
| --- | --- | --- |
| title | `Track.title` | always present |
| artist | `Track.artistName` | nullable; omitted when absent |
| album | `Track.albumName` | nullable; omitted when absent |
| artwork | `Track.artUri` | **when available** — see below |
| duration | live engine duration, falling back to catalog | omitted while unknown |

- **Artwork "when available".** `artUri` is the **token-free** image endpoint for
  Jellyfin and `null` for Subsonic/local tracks (local-folder scanning doesn't
  populate embedded art yet — a separate feature, noted in `android-auto.md`). So
  artwork shows on the lock screen / car for Jellyfin and is gracefully absent
  otherwise. A regression test now asserts `artUri` is mirrored when present and
  `null` when absent (§5).
- **Coalesced, never thrashed.** `_broadcast` (`:194`) re-pushes the media item
  only when its identity/metadata actually changes (`_sameItem`, `:228`) and the
  queue only when its contents/order change (`_sameQueue`, `:287`) — never on a
  position tick. This keeps the car's "Up Next" list and the device's metadata
  stable and is already covered by existing tests.

### Disconnect while playing ("becoming noisy")

When a Bluetooth device disconnects (or wired headphones are unplugged) Android
broadcasts `ACTION_AUDIO_BECOMING_NOISY`. Linthra does **not** handle this with
custom code — and it doesn't need to: `just_audio`'s `AudioPlayer` is constructed
with the default `handleInterruptions: true`
(`just_audio_playback_controller.dart:53`, which overrides only
`audioLoadConfiguration`). Per the `just_audio` docs, with `handleInterruptions:
true` *"the player will automatically pause/duck and resume/unduck when audio
interruptions occur (e.g. a phone call) or when headphones are unplugged."*

- **Pauses safely** — playback pauses, it does not keep blasting from the phone
  speaker.
- **Does not crash** — it is library-managed; the app holds no broadcast receiver
  to mis-handle.
- **Does not resume unexpectedly** — becoming-noisy is a one-way pause; there is no
  code that auto-plays. (Only a *transient* audio-focus interruption that ends
  triggers `just_audio`'s resume, and only if it was playing.)

### Reconnect while paused

- **No auto-play.** Nothing in the app listens for a Bluetooth *connect* to start
  playback. The `MediaSession` won't auto-play on reconnect; playback resumes only
  on an explicit transport command (a media button, the notification, the app).
  This matches the task's "do not auto-play unless Android/media session behaviour
  clearly expects it."
- **State stays consistent.** The queue/current/up-next are owned by the
  controller, independent of output, so a disconnect→reconnect cycle leaves them
  intact (the controller is pinned for the session; see `background-playback.md`).

---

## 2. Bluetooth LE / modern-Android compatibility

**Verdict: compatible — because everything is standard; nothing custom can break LE
audio.**

- **No custom Bluetooth code.** The only platform channel in the app is the SAF
  folder scanner (`MainActivity.kt` / `SafDocumentScanner.kt`,
  `io.github.thezupzup.linthra/saf`). A repo-wide sweep found **no** `Bluetooth`
  API use, **no** `AUDIO_BECOMING_NOISY` `BroadcastReceiver`, **no** custom audio
  focus, and **no** `BLUETOOTH*` permission (which is correct — `MediaSession`
  routing does not require it).
- **Standard media routing.** `just_audio` is built with the default
  `androidApplyAudioAttributes: true`, so playback carries
  `usage = media, contentType = music` attributes. Android's audio framework uses
  those to route to whatever output is active — classic A2DP, **LE Audio**, a car's
  audio, or Android Auto — with no app involvement. LE Audio is an OS-level
  output-routing change; an app that uses standard media attributes + `MediaSession`
  (as Linthra does) needs no LE-specific code.
- **Standard session & service.** `MainActivity` extends `AudioServiceActivity`;
  the manifest declares the `mediaPlayback` foreground service + the
  `MediaBrowserService` intent-filter + `MediaButtonReceiver` (all from
  `audio_service`); Android Auto is declared via `automotive_app_desc.xml`. This is
  the AOSP-recommended model and is what makes Linthra F-Droid-friendly (no Google
  Play Services).

**Optional future hardening (not done here, not required).** Some music apps call
`AudioSession.instance.configure(const AudioSessionConfiguration.music())` at
startup to make the audio attributes / focus-gain explicit. Linthra does **not**,
and does not need to: `just_audio` already *"defaults to music player settings"* for
the session, so an explicit `music()` config would only re-assert the current
behaviour. Adding it touches the live audio path and can't be verified in CI, so
per this phase's safety rules it is **left out**. If pursued later it should be a
small, isolated, device-tested change with the manual checklist below run before and
after.

---

## 3. CPU efficiency

**Verdict: already tight. The Chromecast paused-poll fix (#142) closed the last
known idle wake-up. No further runtime change is warranted.**

### Periodic-timer inventory (the whole app)

A sweep for `Timer.periodic` / `Stream.periodic` found exactly **three** timers,
all bounded or gated:

| Timer | File | When it runs | Gated? |
| --- | --- | --- | --- |
| Position flush (~4 Hz) | `just_audio_playback_controller.dart:149` | only while position ticks arrive (i.e. playing) | ✅ self-cancels when paused/stopped (`_flushPosition`, `:273`) |
| Cast position ticker (250 ms) | `active_playback_controller.dart:184` | only while **casting AND playing** | ✅ `_syncTicker` (`:180`) |
| Cast receiver poll (1 Hz) | `chromecast_cast_transport.dart:227` | only while the receiver is playing/buffering/loading | ✅ `_adjustPolling` (#142, `:241`) |

There is **no** always-on timer, **no** `connectivity_plus` polling
(`OptimisticConnectivityService` is a no-op single-value stream;
`connectivity_plus` isn't wired yet), and **no** continuous animation
(`AnimationController.repeat()` appears **nowhere**; `NowPlayingBackground` is a
static blurred image + gradient).

### Why position ticks don't cause repeated heavy work

The engine's `positionStream` can fire several times a second. Three layers keep
that from turning into CPU churn:

1. **Coalesced at the source.** `JustAudioPlaybackController` buffers the latest
   position and flushes it on a steady 250 ms timer (`_positionFlush`), instead of
   emitting a state per raw tick. The timer **stops** within one interval of the
   last tick, so a paused/stopped player does not wake the isolate.
2. **Change-gated at the session.** `LinthraAudioHandler._broadcast` re-pushes to
   the platform `MediaSession` only when something it renders changes; a steady
   position is re-synced at most every 1 s (`_positionResyncThreshold`, `:101`),
   because `audio_service` interpolates the displayed position between pushes.
3. **Ignored by the side-effect services.** `SmartPrecacheService` and
   `RemotePrebufferService` key off *what to cache/prepare* (track id + up-next +
   shuffle + repeat) and **return early on a position-only tick** (`_keyFor` / `if
   (key == _lastKey) return;`). Cover-art fetches go through Flutter's `ImageCache` (and
   `audio_service`'s notification artwork cache), so the same artwork URL is not
   re-fetched or re-decoded per track.

### UI rebuild scope

No widget watches the whole `playbackStateProvider`; every consumer uses
`.select(...)` for the exact field it needs. So the ~4 Hz position updates rebuild
only the progress bar and (when open) the synced-lyrics list — not the whole
now-playing screen. Those rebuilds happen only while that screen is foregrounded.

### Per-state CPU assessment

| State | Assessment |
| --- | --- |
| Idle app open | No playback timers; UI is event-driven. |
| App background idle (paused) | Position flush cancelled; no cast poll; no app timers — **no periodic wake-ups**. (Manual: confirm over 30 min.) |
| Local playback | CPU is busy decoding regardless; the ~4 Hz flush + ≤1 Hz session push are negligible on top. |
| Streaming playback | As local, plus network buffering tuned for resilience (`_streamBuffering`); preload warms only the immediate next track, sequentially. |
| Paused playback | Engine idle; flush timer stopped; foreground service demoted (`androidStopForegroundOnPause`); wake locks released. |
| Bluetooth playback | Same as local/streaming; routing is OS-level, no extra app work. |
| Cast playback | Local engine suspended (silent); ~1 Hz receiver poll + 250 ms position ticker, both gated to *playing* (#142). |

**Gapless / quality:** no change is proposed, so gapless behaviour and audio
quality are untouched. Buffering tuning and ReplayGain volume are left exactly as
they are.

---

## 4. What this PR changes

Per the phase's safety rules (report first; keep changes small and reviewable; no
playback-stack refactor; no UI change; no telemetry; no battery-optimisation
request), this PR is intentionally minimal:

1. **This audit report** (`docs/audio-bluetooth-cpu-audit.md`).
2. **Regression tests** that lock in the Bluetooth-facing invariants the audit
   verified (see §5), so a future change can't silently regress them.
3. **A manual test checklist** (`docs/manual-test-checklist.md` §3a) for the
   Bluetooth / LE-audio / car / long-idle behaviour CI cannot exercise.

No runtime/playback code is modified.

## 5. Regression tests added

Added to `test/core/services/linthra_audio_handler_test.dart`, group
**"Bluetooth / car media-session surface"**:

- **stable transport capabilities are advertised even at a queue boundary** —
  asserts `systemActions` always contains `seek`, `skipToNext`, `skipToPrevious`,
  and `skipToQueueItem` for a single-track queue, so a Bluetooth device / head unit
  that caches capabilities at connect time keeps Next/Previous live.
- **artwork is mirrored into the now-playing media item when the track has it** —
  asserts `mediaItem.artUri` equals the track's `artworkUri` when present and is
  `null` when absent ("artwork when available").
- **the stop control is always offered to Bluetooth/notification** — asserts
  `MediaControl.stop` is present while playing and while paused.

These complement the existing tests for transport forwarding, metadata, position
coalescing, and the foreground-service-stays-alive invariants.

## 6. Manual test checklist (device-only behaviour)

Bluetooth, LE Audio, car audio, and long-idle wake-ups **cannot** be exercised in
CI. See `docs/manual-test-checklist.md` §3a ("Bluetooth, wired & LE audio") and the
screen-off / paused 30-minute CPU checks, plus the existing
`background-playback.md` screen-off pass.
