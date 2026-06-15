# Battery usage

Linthra aims to be as battery-friendly as a self-hosted music player can be
**without ever lowering audio quality or weakening playback.** Audio fidelity,
gapless behaviour, background playback, and Android Auto are non-negotiable; the
battery work is about avoiding *unnecessary* CPU, network, wake-ups, rebuilds,
scans, and cache work around that fixed audio path — never about doing less for
the sound itself.

This document is the user-and-contributor-facing summary. The read-only
engineering audit of the media/CPU path lives in
[docs/audio-bluetooth-cpu-audit.md](./audio-bluetooth-cpu-audit.md); the
streaming/buffering rationale is in [docs/streaming.md](./streaming.md), and the
cache/pre-cache behaviour in [docs/offline-cache.md](./offline-cache.md).

## What Linthra does to save battery

### Playback service & wake locks

- **The foreground service runs only while audio is actually working.**
  `audio_service`'s media service (and the CPU/Wi-Fi wake locks it holds) is
  promoted to the foreground while the session reports `playing` and demoted on a
  real pause (`androidStopForegroundOnPause: true`). A paused track holds no wake
  lock. See `connectMediaSession` in
  `lib/core/services/linthra_audio_handler.dart`.
- **A mid-stream re-buffer or a track transition never drops the service.**
  The session is reported as `playing` while the engine is actively working
  toward sound — steadily playing, re-buffering, or loading the next track — so
  the OS can't freeze the process with the screen off (which would silence
  streaming until the app is reopened). It only reports `false` on a genuine
  pause/stop/idle/completion/error. See `LinthraAudioHandler._isSessionPlaying`.
- **No custom Bluetooth, audio-focus, or routing code.** Pause-on-disconnect,
  ducking, and media routing are handled by the standard Android
  `MediaSession` + `just_audio`/`audio_service` path — there is no extra polling
  or background machinery layered on top.

### Timers & wake-ups are gated to "only when needed"

The only periodic timers in the app are tightly scoped and self-cancelling:

- **Position flush (~4 Hz)** — the engine's raw position stream is coalesced onto
  a steady ~250 ms cadence so a bursty tick rate can't flood the UI, media
  session, and pre-cache services. The flush timer **stops itself when nothing
  new arrives** (paused/stopped) and restarts on the next position event. See
  `JustAudioPlaybackController._flushPosition`.
- **Media-session pushes (~1 Hz)** — the platform session is updated only when
  something it renders changes (controls, play-state, mode) or when the reported
  position drifts past ~1 s; `audio_service` interpolates the displayed position
  from the wall clock, so steady playback produces ~1 correction a second instead
  of ~5 pushes. Queue and now-playing metadata are de-duplicated and pushed only
  when they actually change. See `LinthraAudioHandler._shouldPushPlayback`.
- **Cast status poll & position ticker** — both run **only while casting and the
  receiver is actually playing**, and stop the moment it pauses. See
  `chromecast_cast_transport.dart` and `ActivePlaybackController._syncTicker`.

### UI rebuilds follow real changes, not the clock

A music player's UI is driven by a position that updates several times a second.
Linthra isolates that so the expensive parts of the tree don't rebuild on every
tick:

- **Now-playing indicator** (the little equalizer on the playing row) uses a
  single animation controller and painter, **stops animating when paused**, and
  **honours the OS reduced-motion setting** (`MediaQuery.disableAnimations`) — a
  paused, off-screen, or reduce-motion indicator schedules no frames. See
  `lib/shared/widgets/now_playing_indicator.dart`.
- **Track rows** watch a position-*independent* now-playing snapshot
  (`current track + isPlaying`), so they rebuild only on a track change or a
  play/pause flip — never on a position tick. See `lib/features/player/now_playing.dart`.
- **Mini-player & now-playing screen** select just the fields they show; only the
  thin progress line and the controls follow the position, not the artwork and
  text around them. See `lib/features/player/mini_player.dart`.
- **Synced lyrics** select the *active line index* (not the raw position), so the
  highlighted-line list rebuilds only when the line actually changes — a handful
  of times per song rather than four times a second for the whole track. The
  sync still moves exactly on each line boundary. See
  `lib/features/player/widgets/lyrics_view.dart`.
- **Queue sheet** selects only the queue identity (current + up-next + history),
  so the open sheet doesn't rebuild on position ticks while you browse it. See
  `lib/features/player/widgets/queue_sheet.dart`.
- **The Now Playing backdrop is rasterized once per cover.** The full-screen
  blurred artwork sits on its own `RepaintBoundary`, so the live progress bar and
  the equalizer indicator painting above it never re-rasterize that expensive
  blur. See `lib/features/player/widgets/now_playing_background.dart`.

### Display refresh rate follows the panel — and yields under battery saver

Linthra opts its window into the display's *native* refresh rate (90 / 120 /
144 Hz where the panel supports it) so scrolling and the Now Playing animations
are smooth on high-refresh phones, instead of the 60 Hz many OEMs hand an app by
default. This is the one place the app touches refresh rate, and it is
deliberately conservative about power:

- **It never hard-codes a rate.** It picks the highest refresh mode that keeps
  the *current resolution* — a seamless switch — and leaves a 60 Hz panel
  untouched. It never lowers resolution to chase a higher rate.
- **Battery saver is the system's call, not the app's.** When the OS is in
  power-save mode the refresh-rate preference is *released* so Android is free to
  drop the rate to save power; Linthra re-evaluates the moment battery saver
  toggles. It never forces a high rate over the system's power management.

See `DisplayRefreshRate` (`android/app/src/main/kotlin/.../DisplayRefreshRate.kt`),
driven from `MainActivity`'s resume/pause.

### Network: event-driven, never polled

- **No background polling, heartbeats, or keep-alives** for Jellyfin or
  Navidrome/Subsonic. The HTTP clients are request/response only.
- **Library sync runs on an explicit "Sync library" action**, with a one-time
  auto-sync on first connecting an account. There is no recurring sync loop.
- **Connectivity is observed, not polled** — Linthra reacts to OS connectivity
  events rather than waking up to test the network.
- **During playback there are no extra network calls per tick** — lyrics are
  fetched once per track (keyed by id, auto-disposed when no longer current), and
  artwork URLs are stable.

### Scans, cache, and artwork: once, on demand

- **Local music is scanned only when you ask** — picking or rescanning a folder,
  retrying after an error, or as a side effect of removing a local file. Opening
  the Library screen reads the already-persisted catalog from the on-device
  database; it does **not** re-walk the filesystem. There is no scan on a timer,
  on resume, or on connectivity change.
- **Embedded cover art is extracted once during the scan** and cached to a
  private `file://` URI; displaying a row loads that cached image and never
  re-extracts tags. See `lib/core/sources/local/`.
- **Cache eviction is event-driven** — it runs when a download/pre-cache commits,
  not on a timer, and the cache snapshot is recomputed only when the cache
  actually changes (and only surfaced while a cache/downloads screen is open).

### Smart pre-cache is bounded and network-aware

Smart pre-cache warms a few upcoming tracks into the offline cache so the next
song starts instantly. It is deliberately modest (see
`lib/core/services/smart_precache_service.dart`):

- It reacts only to changes in **what** to cache (the playing track, up-next,
  shuffle, repeat) — **not** to position ticks.
- It **honours the mobile-data policy**: Wi-Fi always, mobile data only when you
  allow it, never while offline.
- It **stays quiet under repeat-one** (the up-next won't play soon, so caching it
  would waste data and storage).
- It runs **one fetch at a time**, off the playback path, bounded by your
  pre-cache count and the cache size limit, and its entries are evicted before
  any track you pinned with "Keep offline".

### Diagnostics cost nothing in normal playback

All stability/playback diagnostics are gated behind `kDebugMode`, so a release
build does **zero** diagnostics work during playback. Nothing logs per position
tick; the secret-free breadcrumbs that do exist fire only on events (errors,
track changes, output switches) into a small in-memory ring buffer — never to
disk during playback. See `lib/core/diagnostics/` and `*_diagnostics.dart`.

## What Linthra intentionally does **not** do

These are deliberate non-goals — doing them would "save battery" by degrading the
experience, so Linthra does not:

- **Lower audio quality or downsample music.** Bitrate, sample rate, and format
  are never reduced to save power. ReplayGain volume normalization is
  attenuation-only and **off by default**, and only ever changes loudness, never
  fidelity.
- **Disable gapless or other playback features** to cut CPU.
- **Stop or throttle background playback / Android Auto.** Audio keeps playing
  with the screen off and in the car; that is the whole point of the app.
- **Aggressively suppress sync freshness.** Sync is on-demand rather than
  battery-throttled, so your library is correct when you ask for it.
- **Add invasive permissions** (background location, alarms, unrestricted
  background, broad storage) to chase battery wins.

## How you can improve battery life

- **Download / keep tracks offline** for trips and commutes. Playing a cached
  `file://` copy needs no radio and no streaming buffer, which is the single
  biggest battery win for self-hosted libraries. See
  [docs/offline-cache.md](./offline-cache.md).
- **Keep downloads on Wi-Fi.** Leave **"Allow mobile data"** off
  (Settings ▸ Storage & offline) so downloads and pre-cache wait for Wi-Fi
  instead of waking the cellular radio.
- **Tune or turn off smart pre-cache.** Lowering the pre-cache count (or turning
  it off) reduces speculative background fetching if you rarely skip ahead.
- **Enable the system's reduced-motion setting** if you want the now-playing
  equalizer to stay static — Linthra honours it automatically.
- **Pick a nearby/efficient server connection.** A flaky link makes the engine
  re-buffer (and stream) more; a stable connection (or offline copies) keeps the
  radio idle.

## Measuring battery use

Battery work is only safe if it's measurable. Useful levers:

- **`adb shell dumpsys batterystats --charged com.linthra…`** (and
  [Battery Historian](https://github.com/google/battery-historian)) to see wake
  locks, alarms, and radio time attributed to the app across a real session.
- **Flutter DevTools → Performance/CPU** and the **"Track widget builds"** /
  rebuild stats to confirm the now-playing surfaces aren't rebuilding on every
  position tick. The throttling above is covered by tests
  (`test/features/player/lyrics_highlight_throttle_test.dart`,
  `test/features/player/queue_sheet_throttle_test.dart`,
  `test/shared/widgets/now_playing_indicator_test.dart`) so a regression that
  reintroduces per-tick rebuilds fails CI.

## Possible future work (not done here)

Documented for contributors; intentionally left out of the focused battery PR to
avoid risky changes:

- **Incremental local scan.** Today a rescan re-reads every file's tags and
  artwork. Skipping unchanged files (by modification time, where the platform
  exposes it) would make large-library rescans cheaper. It's user-triggered
  today, so it isn't a background drain — just a one-off cost worth trimming.
- **Charging-/power-save-aware pre-cache.** Smart pre-cache already respects
  Wi-Fi vs mobile data; a future option could also pause speculative pre-caching
  under the OS battery-saver or when unplugged below a threshold. This needs a
  battery-state signal and a user-facing setting, so it's deferred rather than
  guessed.
