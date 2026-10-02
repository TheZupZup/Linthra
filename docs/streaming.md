# Streaming & playback

Linthra is designed for **direct streaming** from your self-hosted server, with
an explicit **smart offline cache** for the tracks you choose to keep (see
[offline-cache.md](offline-cache.md)). This page covers how a remote stream is
resolved and played, and how Linthra keeps playback smooth and recovers from
network hiccups.

> **Streaming is not the offline cache.** Stream buffering keeps *live* playback
> smooth; it does **not** write to the offline cache or mark tracks as
> downloaded. Only the explicit download / "Keep offline" / smart pre-cache
> actions populate the on-disk cache.

## How a remote track is resolved

Playback opens whatever URI a `PlayableUriResolver` returns, so local files,
Android SAF `content://` documents, and remote streams all share one path:

1. **Offline first.** If the track has a downloaded copy, it plays from the local
   `file://` cache — no network.
2. **Stream on a miss.** For a Jellyfin/Subsonic track the source verifies the
   session (a tiny reachability check), then mints the **authenticated stream
   URL at play time** and **probes** it (a one-byte ranged GET, following
   redirects) to confirm it's really audio.
3. The minted URL is handed to the engine and **never stored on the track,
   logged, or shown** — see [Security](#security).

`static=true` (Jellyfin) requests the original file bytes — the reliable
"direct play" path — rather than a negotiated transcode/HLS variant.

## Friendly errors

The probe turns server problems into precise, secret-free messages instead of the
engine's opaque "couldn't play". The player distinguishes:

- **not signed in** / **expired session** → prompts a fresh sign-in
- **server unreachable** → "couldn't reach your server"
- **a web page instead of audio** → Cloudflare/Jellyfin access misconfiguration
- **not an audio stream** / **unsupported response** → server/format issue
- **track not available** (404) and a generic **couldn't stream**

These are branched on a typed error *kind*, not message text.

## Buffering & resilience

The engine is configured to buffer generously for remote streams so a brief
network hiccup is absorbed instead of stalling playback:

- a **larger look-ahead buffer** (up to ~2 minutes) so playback keeps going
  through a short drop;
- a healthy **minimum to resume on** after a stall (so it doesn't re-stall
  immediately);
- a **quick initial start** so the first frame isn't delayed.

> **Limitation (documented honestly):** `just_audio` exposes ExoPlayer's
> high-level `LoadControl` (buffer *durations*), not a lower-level per-request
> byte-size knob. So beyond tuning those durations, resilience also comes from
> the **retry/recovery** and **preload** paths below.

## Preloading the next track

While a remote track plays, Linthra warms the **immediate next** remote track's
stream URL ahead of time, so a skip — or the natural roll into the next track —
starts faster instead of re-running the session check + URL probe at the change.

- With shuffle **off** it warms the next track in queue order; with shuffle
  **on**, the next track in the shuffled order (the queue is kept in effective
  play order, so this needs no special-casing).
- Under **repeat-one** it warms nothing — the current track loops, so an
  upcoming track won't play soon.
- It is **best-effort and never blocks** the current track; a failed warm just
  means that track resolves normally when reached.

**This is not the offline cache.** Preloading only holds a **short-lived,
in-memory** resolved URL that is **consumed on first use**. It never writes bytes
to disk, never marks a track as downloaded, and never fills the offline cache —
that is the separate, explicit job of downloads and smart pre-cache (see
[offline-cache.md](offline-cache.md)). Because the warmed URL is consumed on use,
a retry after a failed load always re-resolves a **fresh** URL rather than
replaying a possibly-stale one.

## Recovering from interruptions

If a stream fails **mid-playback**, Linthra recovers rather than dying silently:

- A **transient network drop** gets **one** bounded retry that re-resolves and
  reloads at the **preserved position** (no jump to the start, no duplicate
  playback). The re-resolution re-checks the session/server, so a real outage or
  expiry then surfaces a precise message instead of looping.
- An **expired session** shows a friendly "sign in again" message and is **not**
  retried (no infinite loop).
- A **server-unreachable** failure shows a friendly "couldn't reach your server"
  message.
- An **unsupported format** is reported plainly rather than retried.
- Reaching `playing` again resets the budget, so a *later* independent drop gets
  its own single retry.

The engine's raw error can carry the tokenized stream URL; it is **only
classified, never echoed, logged, or surfaced** — the message shown is always a
fixed, secret-free string.

## When a track can't play at all

When every automatic recovery is spent, the failure becomes something the
listener can act on rather than a dead player. The controller publishes a
`PlaybackFailure` on the playback state: a classified `kind`, a fixed
secret-free message, and the recoveries that are valid *for this failure, right
now*:

| Kind | What it means | Recoveries |
| --- | --- | --- |
| `temporarySource` | server unreachable, connection dropped, a non-audio answer | Retry, another source, Skip |
| `localFileUnavailable` | the file moved, was deleted, or its drive isn't mounted | Retry, another source, Skip |
| `sourceSignInRequired` | no session, or one the server no longer accepts | another source, Skip |
| `unplayableMedia` | unsupported container/codec, corrupt file, no decoder | another source, Skip |

An action is only offered when it can do something: Retry is dropped where
re-presenting the same session or re-reading the same bytes has a fixed answer,
"try another source" appears only for a song that really does exist on another
provider, and Skip only when the queue has a next track.

**Bounded, so it can't become a loop.** Retry and "try another source" share a
budget of three attempts per failing track. When it runs out those actions stop
being offered (Skip remains), and the budget is returned in full the moment
anything actually plays.

**The queue stays put.** A retry re-plays the same queue entry. A source switch
*replaces* that entry with the copy that works, using the same ordered
candidates the automatic runtime fallback uses (see
[playback-source-strategy.md](playback-source-strategy.md)), so the song keeps
its one place in the queue instead of being added again. Skip advances exactly
one track.

The UI is the same on Android and Linux because both read the same model: the
now-playing screen shows the message and the buttons in place of the source
badge (no dialog, and nothing else in the app is blocked), and the
mini-player's second line says, briefly, that the track is failing.

### Moving on by itself, within bounds

Once a track's own recovery is spent, the player (`PlaybackRecoveryPolicy`, the
same on Android and Linux) takes a few bounded steps on its own:

1. **One more try first.** For a source problem (`temporarySource`), the first
   failure waits about ten seconds, then re-resolves the same track with a
   fresh stream URL: at the same position, showing "Reconnecting…", when it
   was playing, or as a fresh load when it never started (so it isn't counted
   as played). That covers a Wi-Fi/LTE handover or a server that blinked. The
   wait is as long as the provider's "this server is down" memory, so the
   retry really asks the server again instead of being answered from that
   memory.
2. **Then the next track, if you allowed it.** Moving on is the
   **Automatically skip tracks that can't play** setting (Settings, under
   Playback), off until you choose. With it on, the player shows the reason
   and counts down five seconds ("Skipping to the next song in 5 seconds",
   with a Stay on this track button), then moves to the next queue entry that
   hasn't already failed in this run (back to the start under repeat-all), so
   a song queued twice is passed over rather than mistaken for the queue
   coming round. Downloaded, pre-cached and local tracks keep playing while a
   server is down. Under repeat-one it stays on the track you chose. With it
   off, the player stops here on the failed track, with Retry, Try another
   source and Skip.
3. **Then it stops.** After six failures in a row, when every other entry has
   already failed in the same run (so repeat-all can't cycle through a dead
   server), or at the end of the queue, the failure is shown with its buttons
   and nothing else happens until you act.

The countdown before each move is five seconds, so the whole run waits about 35
seconds at most, and the per-server reachability memory means a down server is
contacted about once every ten seconds at most while it runs. A track that
plays to its end, or any action of yours (play, skip, seek, Retry, a new
queue), starts a fresh run. It never moves on for an audio engine failure (every track
would fail the same way), after a restored session or the end of a cast (those
never start audio on their own), after you pause, when headphones are
unplugged, or once another app has taken over audio. During a call it can
still load the next track, but starting it is left to the end of the call.

The countdown lives in the playback state the controller publishes
(`PlaybackState.autoSkip`), for exactly as long as the controller's own timer
runs. The screens only draw it, so a skip can't come early, late or twice, and
anything that calls it off (Next, a pause, a new queue, Stay on this track,
turning the setting off) removes it at once. While it runs the media session
still reports a busy state, which keeps Android's foreground service, and so
the timer, alive with the screen off.

The first time a track can't be recovered, while you haven't chosen yet, the
now-playing screen explains the option once ("Sorry, Linthra couldn't play this
song", the reason, and Allow automatic skip / Not now / Details). Either answer
is saved to the same setting and the question isn't asked again. Android Auto
never asks: it follows whatever was saved, and without it a failed track stops
with the car's Next button still working.

## Streaming over mobile data (LTE)

- **Streaming works over LTE by default** when you've chosen to stream — normal
  playback is never treated as a forbidden download/cache action.
- The **Wi-Fi-only gate controls downloads and the offline cache**, not
  streaming playback (see [offline-cache.md](offline-cache.md)).
- **Preloading is conservative on data**: it only warms a single upcoming URL
  (a tiny request, the same one-byte probe play would do anyway) — it never
  downloads track bytes ahead of time.

## Playback states

The player exposes distinct states so the UI is honest and never looks frozen:

| State | Meaning | UI |
| --- | --- | --- |
| `loading` | preparing (resolving + opening) | spinner |
| `buffering` | mid-stream re-buffer (waiting on data) | calm "Buffering…" hint; mini-player spinner; transport stays usable |
| `playing` / `paused` | steady playback | play/pause |
| `error` | a specific, friendly failure | the message plus the recoveries that apply (Retry / another source / Skip) |

`loading` and `buffering` are deliberately separate: a fresh load shows a
spinner, while a mid-stream stall shows a subtle "Buffering…" — so the
mini-player keeps signalling activity and the screen never reads as frozen.

## Security

- A track's stored URI stays the token-free `jellyfin:<id>` / `subsonic:<id>`.
- The authenticated stream/download URL is built **only on demand** and is never
  written to the catalog, logged, shown in the UI, or placed in player state.
- Playback error messages are asserted in tests to contain **no token** — even
  when a transport error would otherwise echo the tokenized URL.
- Diagnostics are secret-free by construction (host only, no token/URL).

## Cast

While casting, the receiver fetches a freshly minted stream URL and the local
engine is suspended, so the phone never plays the same audio twice and a local
playback error can't pull output back from the receiver. A dropped receiver
returns playback to the device **paused** at the last position. Full Cast
behaviour is in [cast.md](cast.md).

## Known limitations

- **No low-level buffer-size knob.** `just_audio` exposes ExoPlayer's
  buffer *durations*, not a per-request byte budget; tuning is at that level.
- **One retry per drop.** Mid-stream recovery attempts a single quick retry by
  design (never an endless loop); a persistent outage gets one delayed retry,
  then playback moves on within the bounds above (if automatic skip is on)
  and finally surfaces a friendly error.
- **Preload warms one track ahead.** Only the immediate next remote track's URL
  is warmed in memory; warming further ahead to *disk* is smart pre-cache's job.
- **Direct play only** — no server-side transcoding fallback for exotic formats.
- **On-device files can't be cast** — a receiver can't reach a `file://` path.
- **Connectivity is optimistic** — the Wi-Fi / mobile-data gate (for downloads)
  relies on a placeholder detector until real detection lands; it does **not**
  block normal streaming playback.

## Manual Android checklist

1. Stream a Jellyfin track over **Wi-Fi**.
2. Stream a Jellyfin track over **LTE / mobile data** (streaming should work by
   default; downloads still respect the Wi-Fi gate).
3. **Skip to next** and confirm it starts faster (the next URL was preloaded).
4. Enable **shuffle** and confirm upcoming tracks still start smoothly.
5. Simulate a **weak network** (briefly toggle airplane mode mid-song).
6. Confirm a **"Buffering…"** state appears instead of an instant failure.
7. Confirm playback **does not restart from the beginning** after recovery.
8. **Cast** a stream and confirm Cast does not desync or fall back to local.
9. Confirm offline cache/download behaviour is **unchanged**.
10. Confirm **no tokenized URLs** appear in the UI, errors, or `adb logcat`.
