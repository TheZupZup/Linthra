# Background & lock-screen playback

Linthra keeps music playing while the screen is off, the phone is locked, or the
app is in the background, using a **foreground media service** (via
`audio_service`) wrapped around the `just_audio` engine. This document explains
how it stays alive, the one field bug that used to break it, and the
device-level settings that can still get in its way.

## How it stays alive

- The single `PlaybackController` owns the `just_audio` engine and is **pinned
  for the whole app session** (never `autoDispose`), so navigating between
  screens, changing settings, or backgrounding the app can never tear it down.
- `LinthraAudioHandler` mirrors the controller's state onto the platform media
  session. While the session reports `playing`, `audio_service` runs a
  **foreground service of type `mediaPlayback`** and holds the CPU + Wi-Fi wake
  locks that keep audio (and streaming) alive with the screen off.
- The app's lifecycle observer **never pauses, stops, or disposes** playback on a
  background transition. It only snapshots the playback state for diagnostics and
  — while casting — re-syncs from the receiver on resume.

### The screen-off bug this fixed

`audio_service` keeps the foreground service (and its wake locks) alive only
while the session reports `playing: true`. It was previously reported as `true`
**only** for the steady `playing` state — so during a mid-stream **re-buffer**
(common when Wi-Fi enters power-save with the screen off) or a **track
transition** the session briefly reported `playing: false`. That demoted the
foreground service, the OS could then freeze the backgrounded process, and audio
went silent until the app was reopened (which un-froze the process and let
playback continue).

The fix: the media session is treated as **playing whenever the engine is
working toward sound** — steadily playing, re-buffering, or loading the next
track — and reports `playing: false` only on a real user pause, stop, idle,
completion, or error. The buffering/loading state still drives the notification
spinner; the foreground service stays up.

### A second screen-off cause: the transient reload idle

Keeping the session `playing` across buffering and `loading` closed most of the
gap, but one transition could still demote the service. The `just_audio` engine
pushes a fresh, default playback event — whose processing state is `idle` — at
the very *start* of every source load (`setUrl`), i.e. on **every track change
and every mid-stream retry reload**, while it is still "playing". Forwarding
that momentary `idle` made the session report `playing: false` for an instant
exactly as the next track loaded — long enough, with the screen off, for the OS
to freeze the backgrounded process (so audio cut out a short time in, typically
at the first track boundary, and only resumed when the app was reopened).

The fix: the controller is the **sole authority on going idle** — it starts idle
and emits its own idle from `stop()` — so it drops the engine's raw `idle` event
entirely. A reload now moves `playing → loading → playing` with no
`playing: false` gap, while a real stop still releases the service.

## Notification permission (Android 13+)

On Android 13+ the media notification and its lock-screen / Bluetooth transport
controls require the `POST_NOTIFICATIONS` runtime permission. Linthra asks for it
once on first launch.

- If you **grant** it: full media notification + lock-screen controls.
- If you **deny** it: audio still plays in the background, but the notification
  and its transport controls are suppressed by the OS. You can re-enable it later
  in **Android Settings ▸ Apps ▸ Linthra ▸ Notifications**.

Settings ▸ Diagnostics reports the current notification-permission state
(`granted` / `denied` / `unknown`) so a "lock-screen controls don't work" report
is self-explaining.

## Battery optimization (device-specific)

Even with everything above correct, some Android OEMs aggressively kill or freeze
background apps for battery. If music **still** stops when the screen is off after
a few minutes, exempt Linthra from battery optimization. This is a
troubleshooting step, not the primary fix — Linthra relies on the foreground
media service first.

- **Stock Android / Pixel:** Settings ▸ Apps ▸ Linthra ▸ App battery usage →
  **Unrestricted**.
- **Samsung (One UI):** Settings ▸ Battery ▸ Background usage limits → remove
  Linthra from "Sleeping apps" / "Deep sleeping apps"; set App battery usage to
  **Unrestricted**.
- **Xiaomi / MIUI:** Settings ▸ Apps ▸ Manage apps ▸ Linthra ▸ Battery saver →
  **No restrictions**; also enable **Autostart**.
- **OPPO / realme / OnePlus (ColorOS / OxygenOS):** Settings ▸ Battery ▸ App
  battery management ▸ Linthra → allow background activity, disable "Sleep
  standby optimization".
- **Huawei (EMUI):** Settings ▸ Battery ▸ App launch ▸ Linthra → **Manage
  manually**, enable Auto-launch, Secondary launch, and Run in background.

(See <https://dontkillmyapp.com> for an up-to-date, per-vendor guide.)

## Diagnostics

Settings ▸ Diagnostics and the on-device "Report a bug" flow include
**secret-free** background-playback fields to make a "stopped when locked" report
actionable — never a token, authenticated URL, track title, or path:

- **Notification permission:** `granted` / `denied` / `unknown`.
- **Audio output:** `local` / `cast`.
- **Last lifecycle:** the most recent app lifecycle state.
- **Playback at last background:** the playback status when the app was last
  backgrounded.
- **Playback state:** the current playback status.
- **Last interruption:** the last safe playback/stream interruption *kind*.

Foreground-service-active and battery-optimization status are **not** reported:
both would require additional native platform code, and the foreground service is
managed entirely by `audio_service`. The battery-optimization guidance above is
the practical substitute.

## Manual Android checklist (screen-off / lock-screen)

Run on a physical device against a real server where possible:

1. Start **local** playback.
2. Turn the screen off for 5 minutes. → Music continues.
3. Wake the phone. → Playback state is correct (not restarted).
4. Start **Jellyfin** streaming.
5. Turn the screen off for 5 minutes. → Stream continues (no silence on
   re-buffer).
6. Test **cached/offline** playback with the screen off. → Continues.
7. Test **Cast** playback with the screen off. → Continues; the phone stays a
   remote, no second local stream.
8. Test **Bluetooth/headset** transport controls while locked.
9. Test **lock-screen** notification controls (play/pause/next/prev/seek).
10. Deny the notification permission (if practical) → background audio still
    plays; controls are suppressed; Diagnostics shows `denied`.
11. Compare **optimized** vs **unrestricted** battery modes; document any device
    that needs the exemption.
12. Confirm reopening Linthra does **not** restart or duplicate playback.
13. Confirm no token or sensitive URL appears in logs or diagnostics.
