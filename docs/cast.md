# Cast / Chromecast

Linthra can hand a Jellyfin or Navidrome/Subsonic stream off to a **Chromecast**
device (a Cast-enabled speaker, TV, or display) on your network. It uses a
pure-Dart implementation of the Google Cast v2 protocol — **no Google Play
Services and no proprietary Cast SDK** — so casting works the same on a sideloaded
or F-Droid-style build.

## Using it

1. Be on the **same Wi-Fi network** as the Cast device.
2. Start playing a **streamed** track (Jellyfin or Subsonic).
3. Tap the **cast icon** in the Now Playing header to open the device sheet.
4. Pick a device. Linthra resolves the stream at cast time, plays it on the
   receiver, and pauses local audio so you don't hear it twice.
5. While connected, the sheet shows a **Cast volume** slider and mute that drive
   the *device's* own volume. Disconnecting (or the receiver dropping) resumes
   local playback, **paused**, at the receiver's last position — so it never
   surprise-starts the phone.

## Good to know

- **On-device (local) files can't be cast** — a receiver can't reach a `file://`
  path on your phone, so only network streams hand off. The sheet says so plainly
  rather than failing silently.
- Discovery uses mDNS, so a device only appears if it's reachable on your LAN
  (some guest/isolated networks block this).
- A device that reports a fixed volume shows an honest disabled state, and a
  failed volume command surfaces a calm notice **without ever interrupting
  playback**.

## How it works (architecture)

The UI renders a `CastState` and drives discovery/connection through the
`CastService` interface, never a cast SDK directly — mirroring how the audio
engine is hidden behind `PlaybackController`.

- Android and iOS get the real `DefaultCastService`, which owns cast state and
  the playback handoff: it resolves the current track's stream URL **at cast
  time**, loads it on the receiver, pauses local audio, and resumes on
  disconnect. It delegates the wire protocol to a thin `ChromecastCastTransport`
  over the pure-Dart `cast` package (Cast v2 over a TLS socket; `bonsoir` for
  discovery). Other platforms keep `UnavailableCastService`, so the button stays
  honest.
- The network-touching transport is isolated, so all of casting's decision-making
  is unit-tested behind a fake `CastTransport`; the only code that opens a socket
  is verified by analysis and on-device testing.
- The single `ActivePlaybackController` keeps one source of truth: while casting,
  the now-playing screen / mini-player / lyrics follow the receiver's
  position/play-state, while the queue stays owned locally and track changes are
  mirrored onto the receiver. This is what fixes Cast desync. See
  [architecture.md](architecture.md#the-single-playback-seam-local--cast).

## Cast volume

While connected, the Cast sheet shows a clearly labelled **Cast volume** slider
plus mute, driving the *device's* own volume (not the phone's media volume) and
following the receiver's reported level live. It is all behind `CastService`
(`setVolume` / `volumeUp` / `volumeDown` / `setMuted`), with `CastState` exposing
`volume` / `muted` / `supportsVolumeControl`.

## Security / token notes

The handoff resolves the current track's stream URL **only at cast time**
(Jellyfin's or Subsonic's authenticated URL, the credential woven in on demand)
and it is **never logged or persisted**. A track's stored reference stays the
token-free `jellyfin:<id>` / `subsonic:<id>`; the receiver is told to fetch a
freshly minted URL that never lands in `Track`, the catalog, a log, or app state.

## Resilience while casting

- A dropped receiver returns playback to the device **paused** at the last
  position, with a friendly Cast/session notice — it never restarts unexpectedly.
- Local engine errors are ignored while casting (the engine is suspended), so a
  cast session never falls back to duplicate local playback. See
  [streaming.md](streaming.md#cast).

## Known limitations

- **On-device files can't be cast** (no receiver-reachable URL).
- Receiver transport controls (volume aside) and local-file casting are
  follow-ups.
- mDNS discovery depends on a LAN that allows it.
