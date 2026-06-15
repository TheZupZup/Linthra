# Remote playback control

Linthra reports its playback to the server that owns the playing track, so it
appears as an active player in that server's dashboard (see
[providers.md](providers.md) and [plex.md](plex.md)). This page covers the
*other* direction — **receiving** remote play / pause / skip / seek commands so
another app (or a speaker remote) can drive Linthra.

Crucially, "remote control" is **not one mechanism**: each provider does it
completely differently, and two of them cannot do it at all. The neutral seam
below lets each provider that *can* be controlled plug in without the rest of
the app knowing how.

## Per-provider status

| Provider | Mechanism | Status |
| --- | --- | :--- |
| **Jellyfin** | Outbound **control WebSocket** (`/socket`) — server pushes `Playstate` commands; client registers `SupportsMediaControl`. NAT-friendly. | ✅ Implemented |
| **Plex** | Inbound **Companion** protocol — GDM discovery + a local HTTP server serving `/player/playback/*`. Needs an inbound socket on-device. | 🔜 Designed — see [plex-remote-control.md](plex-remote-control.md) |
| **Navidrome / Subsonic** | — | ❌ Not possible: the Subsonic API has **no** way for a server to push playback commands to a streaming client. Its only remote-control feature is Jukebox mode (a client commanding *server-side* playback — the inverse). |
| **Local files** | — | ➖ Not applicable: there is no server. External control of local playback is the **system media session** (lock screen, Bluetooth, Android Auto), which Linthra already provides via `audio_service`. |

## The neutral seam

Remote control mirrors the **reporting** seam in reverse. Where
`ServerPlaybackReporter` pushes lifecycle events *out*, a `RemoteControlReceiver`
brings commands *in*; both keep every provider's protocol behind the interface.

- **`RemoteCommand`** (`core/services/remote_command.dart`) — a closed,
  **transport-only** command set: play, pause, playPause, stop, next, previous,
  seek. It has **no** library-mutating case (no playlist, favorite, rating, or
  catalog write), so remote control can never reach past transport into the
  library *by construction*.
- **`RemoteControlReceiver`** (`core/services/remote_control_receiver.dart`) —
  the per-provider seam: owns a transport, surfaces neutral commands on
  `commands`, and is `start()`/`stop()`-able so the transport runs only while
  useful. `NoOpRemoteControlReceiver` covers providers with no remote control.
- **`RemoteControlService`** (`core/services/remote_control_service.dart`) —
  applies each command to the existing **`PlaybackController`**, strictly in
  arrival order, one at a time, swallowing failures. A remote pause therefore
  takes the *exact same path* as an on-screen tap — through cast routing, the
  media session, and server reporting — with no parallel control logic.
- **`RemoteControlActivator`** (`core/services/remote_control_activator.dart`) —
  starts/stops the receiver in step with playback, so the transport is open only
  while a controllable track plays (see Battery).

### Jellyfin specifics

`JellyfinRemoteControlReceiver` (`core/sources/jellyfin/`) connects the server's
`/socket`, registers session capabilities via `POST /Sessions/Capabilities/Full`
(declaring audio + media control), and maps pushed `Playstate` messages
(`Unpause`/`Play`/`Pause`/`PlayPause`/`Stop`/`NextTrack`/`PreviousTrack`/`Seek`)
to neutral commands. It answers `ForceKeepAlive` with periodic `KeepAlive`s and
reconnects after a drop. The WebSocket itself sits behind a tiny
`JellyfinControlSocket` seam (with a `dart:io WebSocket` adapter — **no new
package**, so the committed lockfile is untouched), so the connect/keepalive/
reconnect logic is unit-tested with a fake.

## Battery & network

Linthra's stance is *event-driven, never polled — no background keep-alives*
(see [battery.md](battery.md)). A control socket is in tension with that, so it
is contained:

- **The socket is open only while a controllable track is playing/paused.**
  `RemoteControlActivator` watches playback and `stop()`s the receiver the
  moment playback stops or moves to a non-Jellyfin track — there is no
  persistent signed-in-but-idle socket.
- **Keepalives are server-driven**, answered at half the server's requested
  interval; Linthra never initiates its own heartbeat timer outside an open,
  in-use session.
- **Reconnects use a fixed delay** and stop the instant the activator does.

Follow-ups (not done here): exponential reconnect backoff and foreground-gating;
and the Plex Companion path, whose inbound socket has its own battery profile
(see [plex-remote-control.md](plex-remote-control.md) → Battery).

## Security

- The command set is transport-only, so an authenticated controller can never
  reach the library. Commands run through `PlaybackController` exactly like a
  user tap.
- Jellyfin's token rides in the WebSocket URL's `api_key` query (like the audio
  stream URL) and the capability POST's `Authorization` header; the URL is
  treated as a secret and never logged.
- Nothing about remote control is persisted.

## Tests

`test/core/services/remote_control_service_test.dart`,
`remote_control_activator_test.dart`,
`test/core/sources/jellyfin/jellyfin_remote_command_test.dart`, and
`jellyfin_remote_control_receiver_test.dart` cover command mapping, the
controller bridge, playback-gated activation, capability registration,
keepalive, the signed-out no-op, and stop/disconnect — all with fakes, no real
sockets or servers.
