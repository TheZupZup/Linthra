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
| `error` | a specific, friendly failure | the friendly message |

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
- **One retry per drop.** Mid-stream recovery attempts a single retry by design
  (never an endless loop); a persistent outage surfaces a friendly error.
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
