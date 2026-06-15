# Plex remote control (Companion) — design

> **Status: design only (Plex half).** This page captures the investigation and
> the agreed design for **receiving Plex remote-playback commands** (play /
> pause / skip next / skip previous / stop) so it can be built in small,
> reviewable PRs. **No Plex remote-control code ships with this document.** It
> does **not** register a companion server, open a socket, advertise the player,
> or change playback, and it keeps Plex **read-only from the library's
> perspective** (no playlist or favorites editing). It is the design counterpart
> to
> [docs/plex.md → Playback reporting / Now Playing](plex.md#playback-reporting--now-playing-shipped-after-phase-1),
> which shipped one-way timeline reporting; this is its symmetric follow-up.
>
> **Update:** the provider-neutral remote-control seam this design proposes has
> since shipped, and **Jellyfin** remote control is implemented on it (Jellyfin
> uses an outbound control WebSocket, a different and more NAT-friendly protocol
> than Plex's inbound Companion server). See
> [docs/remote-control.md](remote-control.md) for the cross-provider overview
> and status. This page remains the design for the **Plex Companion** half,
> which is not yet built.

## The symptom

Linthra appears correctly in a Plex Media Server's **Now Playing dashboard**
while a `plex:` track plays — it is listed as an active player, playing,
paused, and progressing. But when the user reaches for the **remote / speaker
controls** in another Plex app (or the server's web dashboard) to pause, play,
skip next, or skip previous *that* player, **Linthra does not react.** The
controls appear to do nothing.

## What is missing today (root cause)

Linthra's Plex playback integration is **one-way**. It *pushes* its state to
the server and never *receives* anything back:

- `PlexPlaybackReporter` (`lib/core/sources/plex/plex_playback_reporter.dart`)
  sends `GET /:/timeline?...&state=playing|paused|stopped&time=…` reports via
  `HttpPlexClient.reportTimeline`. That report is what makes the session appear
  in the Now Playing dashboard.
- The report is a plain outbound HTTP **GET**. There is **no** listening socket,
  **no** discovery broadcast, and **no** command channel anywhere in the app. A
  repo-wide search for `HttpServer`, `RawDatagramSocket`, `ServerSocket`,
  `protocolCapabilities`, GDM, or `/player/…` finds **nothing** in the Plex code
  (the only socket code is the unrelated Chromecast transport under
  `lib/core/services/cast/`).

A timeline report **announces a session**; it does **not** open the channel a
controller uses to drive that session. Those are two different halves of the
Plex protocol, and Linthra only implements the first.

## How Plex remote control actually works (Plex Companion)

Plex remote control is the **Plex Companion** protocol. It is **not** officially
documented by Plex; the description below is reconstructed from
[python-plexapi's `PlexClient`](https://python-plexapi.readthedocs.io/en/latest/modules/client.html),
its [`gdm` module](https://python-plexapi.readthedocs.io/en/latest/modules/gdm.html),
the [Music Assistant "Plex Connect" remote-control plugin](https://github.com/music-assistant/server/pull/2608)
(a recent, real implementation of exactly this), and the community forum threads
on the [`X-Plex-Target-Client-Identifier` header](https://forums.plex.tv/t/player-playback-play-500-internal-server-error-x-plex-target-client-identifier-not-found/236236).
**Every detail here must be re-verified against a real PMS + Plexamp during
implementation** (see [Open questions](#open-questions)).

The crucial fact: **a controllable player runs an HTTP server and is
discoverable.** Control commands are *delivered to the player*, not polled by
it. Concretely, a player must do four things Linthra does none of today:

### 1. Be discoverable — GDM (and/or a reachable registered connection)

Plex discovers players on the LAN with **GDM** ("Good Day Mate"), a small
UDP datagram protocol:

- **Server** discovery uses multicast group `239.0.0.250`, port **32414**.
- **Client/player** discovery uses broadcast `255.255.255.255`, port **32412**
  (with `32413`/`32414` seen in variants).

A controllable player listens for the GDM "hello"/discovery datagram and replies
with a small descriptor (its name, `Content-Type: plex/media-player`, the
`Resource-Identifier` = its client identifier, `protocolCapabilities`, and the
**port** its HTTP server listens on). For control *across networks* (controller
and player on different LANs) GDM does not apply; the player must instead be a
plex.tv-registered device whose connection the controller (or the PMS, see
[proxy-through-server](#4-be-reachable-directly-or-proxied-through-the-pms))
can actually reach — which a phone behind carrier NAT usually is not.

### 2. Serve a capability descriptor — `GET /resources`

The controller fetches `GET /resources` from the player and reads a
`<MediaContainer><Player .../></MediaContainer>` carrying `machineIdentifier`,
`product`, `protocolCapabilities`, etc. The **`protocolCapabilities`** attribute
is a comma-separated list — `timeline,playback,navigation,playqueues,mirror` —
and **a client only receives the commands it declares.** Declaring `playback`
is what makes play/pause/skip reach the player at all.

### 3. Serve the command + timeline endpoints — `/player/…`

The controller sends each transport command as an HTTP request **to the
player's** HTTP server, under `/player/playback/…`:

| Command | Player endpoint | Params |
| --- | --- | --- |
| Play | `GET /player/playback/play` | |
| Pause | `GET /player/playback/pause` | |
| Stop | `GET /player/playback/stop` | |
| Skip next | `GET /player/playback/skipNext` | |
| Skip previous | `GET /player/playback/skipPrevious` | |
| Seek | `GET /player/playback/seekTo` | `offset` (ms) |
| Skip to item | `GET /player/playback/skipTo` | `key` (ratingKey) |
| Step fwd/back | `GET /player/playback/stepForward` / `stepBack` | |
| Volume / shuffle / repeat | `GET /player/playback/setParameters` | `volume` (0–100), `shuffle`, `repeat` |

Every command carries:

- **`commandID`** — a monotonically increasing integer **per controller**. The
  player must track the highest seen per controller and echo it in the timeline
  it returns, so the controller can order and de-duplicate.
- **`type`** — the media type (`music` for Linthra).
- header **`X-Plex-Target-Client-Identifier`** — set to *this player's*
  identifier; the player should reject a command not addressed to it (a missing
  one is a known `500` on the server side).
- header **`X-Plex-Client-Identifier`** — the *controller's* identifier.

To keep the controller's UI in sync, the player also serves the **timeline
subscription** pair:

- `GET /player/timeline/subscribe?protocol=http&port=<n>&commandID=<n>` — the
  controller asks the player to **push** `POST /:/timeline` updates to it (at
  the given host:port) whenever state changes.
- `GET /player/timeline/unsubscribe` — stop pushing.
- `GET /player/timeline/poll?wait=1&commandID=<n>` — the **pull** alternative:
  a controller that can't accept pushes fetches one timeline snapshot from the
  player. (Note: this `poll` is *served by the player* — it is **not** an
  outbound "poll the server for commands" call. There is no such call in the
  protocol.)

### 4. Be reachable directly, or proxied through the PMS

A controller can address the player **directly** (its discovered IP:port) or
ask the **PMS to proxy** the command (`proxyThroughServer`: the controller does
`server.query('/player/…')` with the `X-Plex-Target-Client-Identifier` header
and the PMS forwards it to the registered player). Either path still requires
the player to be **reachable by an HTTP listener** — directly on the LAN, or via
a connection the PMS holds open. There is no path where a NAT'd, listener-less
mobile app receives commands purely by making outbound requests.

## Why "it shows up but won't react" — the two halves

| Half of the protocol | Direction | Linthra today |
| --- | --- | --- |
| Timeline **report** (`GET /:/timeline`) | app → server (push) | ✅ shipped — this is why it appears in Now Playing |
| Companion **command channel** (GDM + `/resources` + `/player/playback/*`) | controller → app (inbound) | ❌ absent — nothing listens, nothing is advertised |

The dashboard lists the session from the report; the remote control needs the
second half, which does not exist. So the controls have **nowhere to send the
command**, and nothing happens.

## Can this ship safely in one small PR?

**No.** Receiving commands is not a tweak to the existing one-way reporter; it
is a **new, always-on, inbound network surface on a mobile device**, with its
own discovery, HTTP server, capability handshake, per-controller `commandID`
bookkeeping, and subscription lifecycle — plus Android foreground-service,
battery, and security implications. Shipping any *partial* slice on its own
would be worse than today:

- Advertising `protocolCapabilities=…,playback` **before** commands are wired
  would make the server offer controls that silently do nothing — i.e. it would
  *deepen* the exact bug being reported.
- A GDM responder or an HTTP server with no command handling advertises a player
  that can't be driven.

So there is **no safe, independently-useful one-PR version**. This matches how
the Plex provider itself was introduced — a design doc first (this file), then a
sequence of small PRs (see [docs/plex.md → Suggested PR steps](plex.md#suggested-pr-steps)).
The breakdown below keeps each PR reviewable and never ships a misleading
half-state.

## Proposed architecture (provider-neutral seam)

Mirror the **reporting** seam that already exists, in reverse. Reporting has a
neutral `ServerPlaybackReporter` contract, a `RoutingServerPlaybackReporter`
that dispatches by uri scheme, and a Plex-specific `PlexPlaybackReporter` behind
it (`lib/core/services/server_playback_reporter.dart`,
`routing_server_playback_reporter.dart`,
`lib/core/sources/plex/plex_playback_reporter.dart`). Receiving commands gets
the symmetric shape:

- **`RemoteControlReceiver`** (new, `core/services/remote_control_receiver.dart`)
  — the neutral contract: `start()` / `stop()` a control channel and a stream of
  neutral **`RemoteCommand`**s (`play`, `pause`, `playPause`, `stop`, `next`,
  `previous`, `seekTo(position)`). A `NoOpRemoteControlReceiver` for providers
  without remote control (everything except Plex today). Commands are **neutral**
  — no Plex types leak out — exactly like `ServerPlaybackReporter` hands
  reporters only a catalog `Track`.
- **`RemoteControlService`** (new) — subscribes to the active receiver's command
  stream and applies each command to the existing **`PlaybackController`**
  (`play()`, `pause()`, `stop()`, `seek()`, `skipToNext()`, `skipToPrevious()`).
  That interface is already the single transport seam the UI and cast both use,
  so commands flow through the *same* path as a user tap — no parallel control
  logic. The service also feeds the receiver the live `PlaybackState` so the
  companion timeline it returns to controllers matches reality, reusing the
  `PlaybackReportingService`'s derived lifecycle rather than re-deriving it.
- **`PlexCompanionServer`** (new, `core/sources/plex/plex_companion_server.dart`)
  — all Plex-specific detail behind the neutral interface: the GDM responder,
  the `dart:io` `HttpServer`, the `/resources` descriptor, parsing
  `/player/playback/*` → `RemoteCommand`, the per-controller `commandID` table,
  and the `/player/timeline/{subscribe,poll,unsubscribe}` lifecycle. It reads
  the live `PlexSession` lazily (signed out → silent no-op), exactly like
  `PlexPlaybackReporter` and the playable-uri resolver. It uses the **same
  `X-Plex-Client-Identifier`** persisted on the session, so the server keys the
  controllable player to the same entry it already shows in Now Playing.

### What the commands are *allowed* to do (hard invariants)

- **Library stays read-only.** `RemoteCommand` covers transport only — play,
  pause, stop, next, previous, seek (and optionally volume). It can **never**
  create/edit/delete a playlist, change favorites, rate, scrobble-write, or
  mutate any library item. The neutral enum simply has no such cases, so the
  invariant is enforced by construction, not by discipline.
- **`skipTo` by `key` is read-only navigation within the current queue**, not a
  library write; phase 1 may decline it (respond but no-op) until queue-jump
  semantics are designed.
- **Non-Plex providers are untouched.** Only `PlexCompanionServer` exists; the
  router starts a receiver only for a live Plex session, so a Jellyfin/Subsonic/
  Local-only user has *no* listening socket and *no* behavior change.

### Token / security safety (same non-negotiables, plus inbound concerns)

The reporting path's rules carry over, and an **inbound server** adds new ones:

- **The companion server never exposes the `X-Plex-Token`.** The token rides
  only in the outbound timeline-push header (as today); it is never placed in a
  served response body, a `/resources` document, a log, or an error. `/resources`
  and timelines are token-free by construction.
- **Commands are authenticated.** A command is honored only when its
  `X-Plex-Target-Client-Identifier` matches this install's identifier; phase 1
  binds the server to the **loopback/LAN** interface and does not register a
  public connection, so the surface is the local network only. Whether to
  additionally verify the controller against the signed-in account is an
  [open question](#open-questions).
- **The listener exists only while signed in to Plex and only while it adds
  value** (see battery, below). Signing out tears it down.
- **No new persisted state.** Subscriptions and `commandID` tables are in-memory
  and die with the session. Nothing about remote control is written to disk.

## Battery & network risk (and how the design contains it)

Linthra's battery stance is explicitly **"event-driven, never polled — no
background polling, heartbeats, or keep-alives"** (see [docs/battery.md](battery.md)).
An always-listening companion server is the single biggest tension with that
stance, so the design contains it deliberately:

- **Risk — a persistent listening socket + GDM responder.** An idle bound
  `HttpServer` is cheap (no busy loop), but holding it open implies the process
  stays alive and reachable. **Mitigation:** bind the server **only while a Plex
  track is the active session** (started ↔ stopped, reusing the reporter's
  lifecycle), not for the whole app lifetime. No Plex playback → no socket.
- **Risk — GDM is multicast/broadcast UDP.** Responding to every discovery probe
  on a busy network is wake-ups. **Mitigation:** only listen while controllable
  (as above); ignore malformed/non-Plex datagrams cheaply; never *initiate*
  periodic broadcasts (respond-only), so there is no timer.
- **Risk — timeline *push* on subscribe could become a per-tick spam.**
  **Mitigation:** reuse the existing throttle (`PlaybackReportingService` already
  collapses ticks to lifecycle + one progress per 10s); push on **state change**,
  not on every position tick.
- **Risk — Android background limits.** A bound socket while the screen is off
  needs the playback foreground service to already be up. **Mitigation:** the
  server only runs *during Plex playback*, when the `audio_service` foreground
  service (and its wake locks) is already promoted — so remote control adds **no
  new** wake lock or foreground-service window beyond what playback already
  holds. It must **never** keep the process alive after playback ends.
- **Risk — `poll?wait=N` long-poll holds a request open.** **Mitigation:** cap
  the wait, cap concurrent subscribers, and drop idle subscriptions.

Net: with the "only while a Plex track is playing, respond-only, reuse the
existing throttle" rules, remote control adds no new *timer* and no new
foreground-service window — it rides the one playback already owns.

## Recommended PR breakdown

Small, incremental, each independently reviewable, and **none ships a state
where the server offers controls that don't work**:

1. **Design doc** — this `docs/plex-remote-control.md`. **No code.** ← *this PR*
2. **Neutral command seam (no I/O, no advertisement).** `RemoteCommand` enum +
   `RemoteControlReceiver` / `NoOpRemoteControlReceiver` contract +
   `RemoteControlService` that maps commands → `PlaybackController`. Fully
   unit-tested with a `FakeRemoteControlReceiver`; **nothing binds a socket and
   nothing is advertised**, so the app's behavior is unchanged.
3. **Pure Companion protocol units.** A `/player/playback/*` request →
   `RemoteCommand` parser, a `/resources` descriptor builder, a per-controller
   `commandID` tracker, and a GDM datagram parse/format helper — **pure
   functions, no sockets**, exhaustively unit-tested (incl. token-free output
   and rejecting commands not addressed to this client).
4. **`PlexCompanionServer` — HTTP server, wired but feature-flagged off.** Bind
   a `dart:io` `HttpServer`, serve `/resources` + `/player/playback/*` +
   `/player/timeline/*`, emit neutral commands. Behind an **off-by-default**
   setting so it can be tested on a real device without changing default
   behavior. Tests drive the server with a fake controller over loopback.
5. **GDM discovery responder.** Respond to discovery probes so controllers find
   the player on the LAN, advertising `protocolCapabilities` incl. `playback`.
   Still feature-flagged.
6. **Lifecycle wiring + enable.** Start the receiver only while a Plex track is
   the active session (reuse the reporter lifecycle), tear it down on stop /
   sign-out / app exit; verify the foreground-service interaction; then flip the
   flag on (or expose a Settings toggle). This is the PR that makes the controls
   work end-to-end. Tests cover start/stop on session boundaries and a clean
   teardown on sign-out.
7. **(Optional, later) Remote reachability.** Register a connection with plex.tv
   / proxy-through-server so control works across networks, *if* it proves
   feasible and safe behind NAT — likely its own design note.

Stop after step 1 (this PR) and confirm the design before building 2+. Steps
2–3 are safe to land early (pure, untested-surface-free); the behavior change
only arrives at step 6.

## Tests to add (per the repo's `Fake*` + Riverpod-override style)

Mirrors the Jellyfin/Subsonic/Plex test layout; no mocking library.

- `remote_command_test.dart` — neutral command mapping → `PlaybackController`
  calls (play/pause/stop/next/previous/seek), with a `FakePlaybackController`.
- `remote_control_service_test.dart` — a command stream drives exactly the right
  controller calls, in order; a no-op receiver causes nothing.
- `plex_companion_endpoints_test.dart` — `/player/playback/*` → `RemoteCommand`
  parsing, `type`/`commandID` handling, rejecting a command whose
  `X-Plex-Target-Client-Identifier` isn't ours, and `seekTo` offset parsing.
- `plex_resources_descriptor_test.dart` — the `/resources` document declares
  `playback` capability and is **token-free**.
- `plex_command_id_test.dart` — per-controller monotonic tracking + echo.
- `plex_gdm_test.dart` — discovery datagram parse/format, ignore non-Plex.
- `plex_companion_server_test.dart` — drive a loopback `HttpServer` with a fake
  controller: a command turns into a `PlaybackController` call; a foreign target
  identifier is refused; no response body ever carries the token.
- A **guard test** that with no Plex session (or a non-Plex-only setup) **no
  socket is bound and nothing is advertised** — the no-behavior-change invariant.
- A **library-read-only guard**: the `RemoteCommand` surface has no
  library-mutating case, and no command path calls any catalog/playlist/favorites
  write.

## Open questions

Decide these before/while building, ideally against a real PMS + Plexamp:

- **Exact GDM ports & datagram shape**, and the precise `/resources` /
  `Player` descriptor a current PMS/Plexamp expects — the protocol is
  reverse-engineered, so validate empirically.
- **Direct-LAN only vs proxy-through-server**: is LAN control enough for phase 1
  (almost certainly yes), deferring cross-network control to a later note?
- **Controller authentication**: is matching `X-Plex-Target-Client-Identifier`
  + LAN-binding sufficient, or should commands be checked against the signed-in
  account/token?
- **Default on or behind a Settings toggle?** Given the inbound-socket surface,
  a default-off toggle (with a clear "let Plex apps control this player"
  explanation) is the conservative first ship.
- **`stop` semantics**: map Companion `stop` to `PlaybackController.stop()` —
  safe and already supported — vs treating it as pause. Stop is in scope and
  safe; confirm it shouldn't instead tear down the queue.

## Notes

- This design must **not** change existing providers. The only shared-code
  additions are the new neutral `RemoteControlReceiver`/`RemoteControlService`
  seam (used by Plex alone today) and wiring that starts a receiver **only** for
  a live Plex session.
- Reuse, don't reinvent: `PlaybackController` is the existing transport seam,
  `PlaybackReportingService` already derives the playback lifecycle and throttle,
  `dart:io` provides `HttpServer`/`RawDatagramSocket`, and the `Fake*`-client +
  Riverpod-override test style is already in place.
- Credentials follow the same non-negotiables as every other provider: the token
  is never logged, never served in a response, and never woven into a persisted
  value.
</content>
</invoke>
