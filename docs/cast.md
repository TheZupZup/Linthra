# Cast / Chromecast

> **Casting is temporarily unavailable.** It is switched off in shipped builds
> while a reported security issue is resolved. Local playback, downloads, and
> every server integration are unaffected, and your queue and settings are
> untouched. See [Temporary containment](#temporary-containment) below, and
> issues [#572](https://github.com/TheZupZup/Linthra/issues/572) and
> [#575](https://github.com/TheZupZup/Linthra/issues/575). The rest of this page
> describes how casting works and will work again once it is restored.

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

## What the receiver shows (metadata)

When Linthra hands a track to the **default media receiver**, it sends the track's
metadata so the TV/speaker/display shows what's playing rather than a bare URL:

| Field | Sent? | Source |
| --- | --- | --- |
| **Title** | ✅ | the track title |
| **Artist** | ✅ when known | the track artist |
| **Album** | ✅ when known | the track album |
| **Duration** | ✅ when known | the track's catalog duration (so the seek bar has a length immediately) |
| **Artwork** | ✅ Jellyfin · ❌ Subsonic | see below |

This metadata is built in one tested place — `CastLoadMessage` (in
`lib/core/services/cast/`) — from a `CastMedia` produced by the source's
`CastMediaResolver`. `ChromecastCastTransport` only serialises that message onto
the wire, so metadata formatting never scatters across the app or into a widget.
When the current track changes, the new track's metadata is sent automatically; a
re-emission of the *same* track is a no-op, so steady playback never reloads the
stream just to refresh metadata.

### Artwork

- **Jellyfin** cover art (`/Items/<id>/Images/Primary`) needs no auth, so it is a
  safe, token-free URL the receiver can fetch directly — Linthra sends it.
- **Subsonic/Navidrome** cover art (`getCoverArt`) requires the salt+token in its
  query, so sending it would leak the credential to the receiver. Linthra
  **omits** Subsonic artwork rather than leak a token. (A token-free cover proxy
  is a possible follow-up.)

Artwork is only ever sent when it is a URL the receiver can actually reach without
a credential; otherwise it is omitted.

## Receiver app name / logo (branding)

**The receiver shows "Default Media Receiver" (and your Cast device's name), not a
Linthra name or logo.** This is a limitation of the *default* Cast media receiver,
not something Linthra can fix from the sender:

- The app name and logo shown on a Cast device are fixed by the **receiver
  application** that's running on the device, not by the sender or by any media
  metadata field. There is no Cast field that lets a sender set the receiver's
  displayed app name or logo.
- Linthra uses Google's published **default media receiver** (app id `CC1AD845`)
  so casting needs **no Google Play Services and no proprietary Cast SDK**, which
  is what keeps it F-Droid/open-source friendly. That receiver renders the media
  metadata above, but always under its own generic branding.
- Showing **"Linthra" + the Linthra logo** on the receiver would require shipping a
  **custom Cast receiver application** — a small hosted HTML/JS app registered in
  Google's Cast Developer Console under a Linthra-owned app id. That is a hosting +
  registration commitment (and arguably a Play-Services-adjacent dependency), so
  it is **out of scope** for now and tracked as a follow-up.

Linthra deliberately **does not fake** app branding it can't deliver: it improves
exactly what the default receiver *can* show (title / artist / album / duration /
artwork) and is honest about the rest.

## How it works (architecture)

The UI renders a `CastState` and drives discovery/connection through the
`CastService` interface, never a cast SDK directly — mirroring how the audio
engine is hidden behind `PlaybackController`.

- `DefaultCastService` owns cast state and the playback handoff: it resolves the
  current track's stream URL **at cast time**, loads it on the receiver, pauses
  local audio, and resumes on disconnect. It delegates the wire protocol to a
  thin `ChromecastCastTransport` over the pure-Dart `cast` package (Cast v2 over
  a TLS socket; `bonsoir` for discovery). **While containment is in place no
  build binds it**: every platform gets `UnavailableCastService`.
- The network-touching transport is isolated, so all of casting's decision-making
  is unit-tested behind a fake `CastTransport`; the only code that opens a socket
  is verified by analysis and on-device testing.
- The single `ActivePlaybackController` keeps one source of truth: while casting,
  the now-playing screen / mini-player / lyrics follow the receiver's
  position/play-state, while the queue stays owned locally and track changes are
  mirrored onto the receiver. This is what fixes Cast desync. See
  [architecture.md](architecture.md#the-single-playback-seam-local--cast).

## Temporary containment

Casting is withheld from production builds by `CastContainment` while a reported
security issue is resolved. The report, its assessment, and the requirements a
restoration has to meet are held in the repository's private security advisory
and are not reproduced here, in the code, or in pull requests, until coordinated
disclosure. If you are picking this work up, ask a maintainer for advisory
access rather than inferring the details from the code.

It is enforced at three independent layers, because a containment one edit can
undo is not a containment:

1. **Production wiring** — `containedCastServiceOverride` binds
   `UnavailableCastService` on every platform. No live backend is constructed,
   so there is nothing to discover or connect with.
2. **Transport** — `ChromecastCastTransport` refuses discovery and connection
   outright. Re-wiring the service on its own, or injecting the transport from
   somewhere else, still cannot open a receiver socket.
3. **Media handoff** — the session handle refuses to hand media to a receiver,
   so a session obtained some other way is still given nothing.

`CastContainment.isActive` is a compile-time constant. There is deliberately no
setting, environment variable, or debug affordance that flips it: an unreviewed
runtime switch would be a second production path with none of the review the
restoration requires.

What demonstrates the containment is the test suite: the production-wiring tests
build the real override list per platform and drive the service, and the
transport tests call it directly. `scripts/check_cast_containment.py`, which also
runs in CI, is a much weaker tripwire on top of that — it matches source patterns
and only catches the obvious removals it knows about. Its limitations are written
down in the script itself; it is not evidence that casting cannot be reached.

Both of those look at the source tree. A release also has to answer a different
question — is the safeguard in the file people actually install? — so
`scripts/verify_release_containment.py` reads the compiled Dart inside the built
APK/AAB/tarball, and the release workflows run it before an artifact is uploaded
and again on the published assets. The shipped `v0.2.6` artifacts and their
SHA-256 digests are recorded in
[release-artifact-verification.md](release-artifact-verification.md).

In the app, the cast button stays visible but muted and the sheet says casting is
temporarily unavailable — it does not claim the platform is unsupported, which
would be untrue on the phones this affects.

### Restoring casting

Restoration is a separate, reviewed change, not a revert. Its requirements are
tracked publicly in [#575](https://github.com/TheZupZup/Linthra/issues/575), and
in detail in the private advisory, which is where that work is reviewed before
anything is restored. [#576](https://github.com/TheZupZup/Linthra/issues/576) is
an additional layer, not a substitute for it.

The trust model, the contract already in the tree (`CastReceiverAuthenticator`
and the fail-closed `TrustGatedCastTransport`), the implementation options and
the test matrix are in
[cast-receiver-trust.md](cast-receiver-trust.md), and the concrete design for
what a real receiver check would have to do (the Cast device-authentication
exchange, the pinned trust anchors, per-device pinning, and where the
cryptography would come from) is in
[cast-hardened-design.md](cast-hardened-design.md). What a handoff delegates to a
receiver, per server, is in [cast-media-access.md](cast-media-access.md).

The reviewed restoration updates `CastContainment`, the production wiring, the
transport guards, and `scripts/check_cast_containment.py` in one pull request.

## Cast volume

While connected, the Cast sheet shows a clearly labelled **Cast volume** slider
plus mute, driving the *device's* own volume (not the phone's media volume) and
following the receiver's reported level live. It is all behind `CastService`
(`setVolume` / `volumeUp` / `volumeDown` / `setMuted`), with `CastState` exposing
`volume` / `muted` / `supportsVolumeControl`.

## Security / token notes

These describe the handoff as designed; while casting is contained, none of it
runs, because no handoff happens at all.

The handoff resolves the current track's stream URL **only at cast time**
(Jellyfin's or Subsonic's authenticated URL, the credential woven in on demand)
and it is **never logged or persisted**. A track's stored reference stays the
token-free `jellyfin:<id>` / `subsonic:<id>`, so the minted URL never lands in
`Track`, the catalog, a log, or app state.

- **The receiver never gets that URL.** `DefaultCastService` hands it to the
  on-device relay (`LocalCastMediaProxy`), which keeps it on the phone and gives
  the receiver `http://<phone-lan-ip>:<port>/cast/<token>` instead: a random
  token for that one item, dead once the receiver has accepted the next item
  or the session ends. The phone fetches the stream itself and relays it, `Range` requests
  included, so seeking still works.
- **The relay lives only as long as the session.** It starts when casting
  starts and stops on disconnect, on a dropped receiver, or after a long idle
  spell. If it cannot start, casting is off for that session with a clear
  message; there is no fallback that sends the server URL.
- **Nothing else carries a credential.** The displayed metadata (title / artist
  / album / artwork) never embeds one; `CastMedia.toString()` redacts the URL
  down to scheme/host/path; and the only diagnostics line emitted at cast time
  has no field for a token or full URL.
- **Artwork follows the same rule**: a tokenised cover-art URL is never sent.
  Jellyfin's cover art is token-free (sent); Subsonic's needs the credential
  (omitted).

What each server would otherwise force a handoff to carry, and how the relay is
guarded (exposure, token lifetime, what it relays back, what it costs), is in
[cast-media-access.md](cast-media-access.md). The relay does not replace
receiver authentication: casting stays contained until that lands.

## Resilience while casting

- A dropped receiver returns playback to the device **paused** at the last
  position, with a friendly Cast/session notice — it never restarts unexpectedly.
- Local engine errors are ignored while casting (the engine is suspended), so a
  cast session never falls back to duplicate local playback. See
  [streaming.md](streaming.md#cast).

## Known limitations

- **Casting is off in shipped builds** pending the security fix above. Everything
  below describes the feature as built, for when it returns.
- **No Linthra app name/logo on the receiver** with the default media receiver —
  it shows "Default Media Receiver". True branding needs a custom receiver app
  (see [above](#receiver-app-name--logo-branding)). Tracked as a follow-up.
- **Subsonic/Navidrome artwork is not shown** on the receiver, because its
  cover-art URL would leak the credential. Jellyfin artwork is shown.
- **On-device files can't be cast** (no receiver-reachable URL).
- Receiver transport controls (volume aside) and local-file casting are
  follow-ups.
- Per-track content type is a best-effort `audio/mpeg` hint; an exact MIME /
  transcoded cast profile for exotic codecs is a follow-up.
- mDNS discovery depends on a LAN that allows it.
