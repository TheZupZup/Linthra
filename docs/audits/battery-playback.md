# Audit — battery use during normal playback

This is the report for issue #344 ("Investigate high battery drain during normal
playback"). It is a read-through of everything that runs while music is playing,
checked against what [docs/features/battery.md](../features/battery.md) claims, plus the focused
fixes the read-through justified and the measurements behind them.

**Scope:** the work the app does *around* the audio, in both listening shapes
the issue asks about — screen off with the app backgrounded, and Now Playing
left open. Audio quality, gapless, background playback, Android Auto and
streaming behaviour are untouched by everything here; nothing was disabled to
make a number look better.

> **Bottom line.** Most of what `docs/features/battery.md` describes is real and holds up:
> the foreground service and wake locks follow playback, the position flush is
> coalesced and self-cancelling and the UI surfaces are properly isolated from
> it. Two things did not match the document, and both ran for the *whole* length
> of a screen-off session:
>
> 1. **A configured Jellyfin server was re-probed every 45 s regardless of
>    whether the app was on screen** — about **80 network round-trips an hour**
>    with the screen off, against a document that says "no background polling",
>    and radio wake-ups on mobile data.
> 2. **Several services rebuilt work per position tick** (~4 Hz) that they then
>    threw away — fingerprint strings over the whole up-next list, and a
>    re-materialized media-session queue window. Measured on a 5000-track
>    up-next: **~292 ms of CPU per five minutes of playback**, all of it
>    discarded.
>
> Both are fixed here. A third, Linux-only finding (the crash-safe session
> rewriting its whole document every 2 s) is fixed too. The refresh-rate and
> Now Playing findings are documented rather than changed, with reasons.

---

## How this was audited

- Read the playback path end to end: `just_audio_playback_controller.dart`,
  `active_playback_controller.dart`, `linthra_audio_handler.dart`, and every
  service that subscribes to the unified `PlaybackState` stream
  (`smart_precache_service.dart`, `remote_prebuffer_service.dart`,
  `media_artwork_prewarm_service.dart`, `playback_reporting_service.dart`,
  `playback_session_persistence.dart`, the MPRIS session).
- Swept the Dart sources for everything that can fire without the user:
  `Timer`, `Timer.periodic`, `Stream.periodic`, `AnimationController`,
  `.repeat(`, and every `.listen(` on the playback stream.
- Read the Android side for the refresh-rate and lifecycle behaviour
  (`MainActivity.kt`, `DisplayRefreshRate.kt`).
- Checked each claim in `docs/features/battery.md` against the code, which is what turned
  up findings 1 and 2 — the document was describing an intent the code had
  drifted from.
- Measured the per-tick cost with a new harness,
  `test/benchmarks/playback_tick_cost_bench.dart`, before and after each change,
  on the same machine in the same session.

**What this audit could not do:** run `batterystats` on a real phone. No device
was available, so there is no "X% per hour before / Y% after" figure here. The
measurements below are counted work — requests per hour, writes per hour, CPU
microseconds per tick — which is what the fixes actually remove. An on-device
`dumpsys batterystats --charged` comparison across a 30–60 minute session is
still worth doing, and the checklist for it is at the end.

---

## 1. The availability probe polled with the screen off

**Verdict: real, and the biggest single wake-up source. Fixed.**

`JellyfinAvailabilityController` re-probes a configured server on a timer so
that walking back onto the home network restores the library on its own. In
production that interval is 45 s. The timer was started whenever a server was
configured and cancelled only when the provider was disposed — and the provider
is watched by the active library, so in practice it never was.

That is the opposite of what the app is built to do everywhere else, and it is
worst exactly where it hurts: `audio_service` deliberately keeps the process and
the Flutter isolate alive during screen-off playback (see the foreground-service
section of `docs/features/battery.md`), so this timer kept firing for the entire session.
**About 80 authenticated round-trips an hour, refreshing a library nobody could
see** — and on mobile data, 80 chances an hour to pull the radio out of idle.
`docs/features/battery.md` claimed "No background polling, heartbeats, or keep-alives".

**Fix.** The poll now follows app visibility. `AppVisibility`
(`lib/core/lifecycle/app_visibility.dart`) is a small signal published by the
root widget's lifecycle observer; the controller starts the timer when the UI is
shown and cancels it when it is hidden. Nothing else changes: the resume path
already re-probes immediately when you come back, the playback path still
reports what it learns through `noteReachability` whether the UI is up or not,
and a hide/show flip deliberately does not re-run the notifier's `build` — that
would reset a settled answer to `checking` and blink the library.

| | Before | After |
| --- | --- | --- |
| Probes/hour, app on screen | ~80 | ~80 (unchanged) |
| Probes/hour, screen off while playing | ~80 | **0** |
| Time to recover the library on return | ≤ 45 s | immediate (resume probe) |

Covered by `test/features/settings/jellyfin/jellyfin_availability_controller_test.dart`
("the poll follows app visibility") and the wiring test in
`test/app/playback_lifecycle_test.dart`.

## 2. Per-tick work that was thrown away

**Verdict: real. Fixed.**

The engine's position stream is coalesced to a steady ~4 Hz flush (that part
works as documented). Every one of those ticks is delivered to each service
listening on the unified state stream, and each service starts by deciding
whether anything it cares about changed. The *deciding* was the problem:

- `SmartPrecacheService` built a fingerprint **string over the entire up-next
  list** — on every tick. Selecting "play all" on a large library means that
  string is the whole queue, rebuilt four times a second, for the whole session.
- `RemotePrebufferService` did the same over the head of the queue, and
  `MediaArtworkPrewarmService` over its look-ahead: smaller, same shape.
- `LinthraAudioHandler._broadcast` re-materialized the published queue window
  (up to 250 tracks) and rebuilt a `MediaItem` on every tick, only to compare
  them and conclude nothing had changed.

None of it was *wrong* — the comparisons all reached the right answer, which is
why no test caught it — it was just work done to discover that there was no work
to do.

**Fix.** One shared, allocation-free test replaces the fingerprint strings:
`samePlaybackLookahead` (`lib/core/services/playback_lookahead.dart`) compares
the current track, shuffle/repeat, and only the head of up-next each service can
actually warm, short-circuiting on object identity — `PlaybackState.copyWith`
passes the queue lists straight through, so an unchanged queue is provably
unchanged in constant time. The media-session bridge got the same treatment: a
tick whose queue objects, track, and duration are identical to the last
broadcast skips straight to the playback-state push (which still follows the
position and re-syncs on drift, as before). A cover finishing its warm forces a
re-publish, since artwork resolves outside `PlaybackState`.

Measured with `test/benchmarks/playback_tick_cost_bench.dart`, 1200 ticks
(≈ 5 minutes of playback), median of 3 runs, same machine:

| Case | Before | After |
| --- | --- | --- |
| Stream only (the floor: building + delivering the states) | 14.7 ms | 14.4 ms |
| Media-session bridge, 20 000-track queue | 34.3 ms | 25.7 ms |
| Look-ahead services, 5000-track up-next | 306.6 ms | 23.8 ms |

Net of the floor, that is **~19 ms → ~11 ms** for the media-session bridge and
**~291 ms → ~9 ms** for the look-ahead services per five minutes of playback —
about a 30× reduction on the latter. Per hour of screen-off listening, roughly
3.5 s of pure-waste CPU becomes about 0.1 s. On its own that is not a battery
meter moving; it is the constant background hum that makes the CPU harder to
keep parked, and it scales with the user's queue size, which is exactly the
"few songs and I'm reaching for a charger" shape the issue describes.

Behaviour is unchanged and locked in by
`test/core/services/playback_lookahead_test.dart` plus two new cases in
`linthra_audio_handler_test.dart` (a rebuilt-but-equal queue is still not
re-published; a duration arriving for the same track still updates the item).

## 3. The Linux crash-safe session rewrote itself every 2 seconds

**Verdict: real, Linux only. Fixed.**

`PlaybackSessionPersistence` (constructed on Linux only — Android has no
equivalent) persisted the logical queue so an unexpected restart can restore it.
Structural changes wrote immediately, which is right; position ticks were
debounced to **2 s**, which is not. Every one of those writes re-encodes the
*whole* document and rewrites the store's single key.

Measured: a 200-track queue encodes to **28.8 KB in ~0.57 ms**. At a 2 s
debounce that is **~1800 encodes and 1800 rewrites an hour** — around a second
of CPU per hour spent serialising, plus the disk traffic, for a record only a
crash ever reads.

There was a second, quieter bug in it: the debounced save wrote the state that
*armed* the timer, not the freshest one, so the record was already stale when it
landed.

**Fix.** The debounce is now 10 s and writes the freshest position seen, and
`dispose()` flushes a pending position so a clean quit records exactly where
playback was. Everything meaningful still persists immediately — track change,
queue edit, pause, stop, shutdown — so what the longer interval bounds is only
what an unexpected kill *mid-playback* can lose: up to 10 s of position instead
of up to 4 s. Writes drop from ~1800/hour to ~360/hour.

Covered by the "position saves are coalesced (battery)" group in
`test/core/services/playback_session_persistence_test.dart`.

## 4. Now Playing, artwork and the blur

**Verdict: matches the document. No change.**

Checked because the issue asks specifically about the open Now Playing screen:

- The full-screen blurred backdrop sits on its own `RepaintBoundary` and is
  keyed by the artwork URI, so the live progress bar and the equalizer painting
  above it never re-rasterize the 40px gaussian blur.
- The wavy progress bar really has no perpetual animation — one ~420 ms swell
  per play/pause flip, skipped under reduced motion, then no scheduled frames.
- Track rows, the queue sheet, and the synced-lyrics viewport all select
  position-*independent* slices, so a tick doesn't rebuild them.
- Only the slim `_LiveControls` column follows the position on the now-playing
  screen; the artwork and metadata around it do not.

Nothing here needed changing. These are already covered by the throttle tests
listed in `docs/features/battery.md`.

## 5. Refresh rate while the app is open

**Verdict: correct as designed, with a real cost worth naming. Documented, not
changed.**

`DisplayRefreshRate` picks the highest refresh mode *at the current resolution*,
never lowers resolution, leaves a 60 Hz panel alone, and releases the pin
entirely under battery saver (re-evaluating on the OS broadcast). That is all as
documented.

The cost the document doesn't name: `preferredDisplayModeId` is a *pin*, so
while the app is foregrounded the panel is held at that mode even when nothing
is moving — a static Now Playing screen at 120 Hz that the system would
otherwise have dropped to an idle rate. It is only paid while the app is on
screen (a screen-off session is unaffected, which is the case the issue is
mostly about), and releasing the pin when nothing is animating risks a stutter
on the first flick of a scroll. Left alone deliberately; recorded under "possible
future work" in `docs/features/battery.md` so the next person measuring has the context.

## 6. Server playback reports

**Verdict: correct and bounded. Documented more honestly.**

A *streamed* track sends start / pause / resume / stop, plus a progress ping at
most every 10 s while playing — the standard reporting a Jellyfin / Plex /
Subsonic server needs to show Linthra as an active player. It is off the
playback path, throttled by `PlaybackReportingService.progressInterval`, and a
local or cached track sends nothing at all. It also rides a radio the stream is
already keeping busy, so its marginal cost is small.

`docs/features/battery.md` said "no extra network calls per tick", which is true but
skipped past this; it now names the 10 s report explicitly. No code change:
lengthening the interval risks servers timing the session out, which is a
correctness regression for a feature people use.

## What was checked and found already correct

Short version, so a future audit doesn't have to re-derive it:

- Foreground service / wake locks follow real playback, with the deliberate
  transient-focus hold, and a re-buffer or track transition never demotes it.
- The ~4 Hz position flush stops itself when nothing new arrives and restarts on
  the next event.
- Media-session pushes are gated on what the session renders plus a ~1 s
  position drift; `audio_service` interpolates the rest.
- The cast status poll and cast position ticker run only while casting *and*
  playing.
- Smart pre-cache reacts to what-to-cache changes only, honours the mobile-data
  policy, stays quiet under repeat-one, and runs one fetch at a time.
- Local scans are user-triggered only; cover art is extracted once at scan time;
  cache eviction is event-driven.
- Diagnostics are `kDebugMode`-gated for logging and otherwise write only to a
  bounded in-memory ring buffer — nothing per tick, nothing to disk.
- The Jellyfin remote-control keep-alive exists only while remote control is
  actually on, and replies on the interval the server asks for.

## Still worth doing on a real device

This audit removed measurable work but could not close the loop on a phone. The
run that would:

1. Charge to 100 %, `adb shell dumpsys batterystats --reset`.
2. 30–60 minutes of playback, screen off, app backgrounded — once from a
   streamed source, once from downloaded/offline tracks.
3. The same again with Now Playing left open, screen on, untouched.
4. `adb shell dumpsys batterystats --charged <package>` for each, through
   [Battery Historian](https://github.com/google/battery-historian): wake locks,
   mobile-radio active time, wake-up counts, and CPU time attributed to the app.
5. Compare against the same runs on the commit before this change.

The specific predictions to check: **zero** availability requests in the
screen-off runs, unchanged wake-lock behaviour (the foreground service must
still hold across playback exactly as before), and lower app CPU time in the
runs with a long queue.
