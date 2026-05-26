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

- **Direct play only** — no server-side transcoding fallback for exotic formats.
- **On-device files can't be cast** — a receiver can't reach a `file://` path.
- **Connectivity is optimistic** — the Wi-Fi / mobile-data gate (for downloads)
  relies on a placeholder detector until real detection lands; it does **not**
  block normal streaming playback.
