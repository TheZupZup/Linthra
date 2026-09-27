# What a cast handoff delegates (least-privilege media access)

When Linthra casts, it stops fetching the audio and tells a device on the
network to fetch it instead. That device needs to be allowed to, so something is
delegated. This page is what each supported server actually lets us delegate,
what that costs, and what would have to change for a handoff to give a receiver
no more than the one song it is playing. It tracks
[#576](https://github.com/TheZupZup/Linthra/issues/576).

This is defence in depth, not the fix. Narrowing what a receiver gets does not
make an unauthenticated receiver safe to talk to — that is
[#575](https://github.com/TheZupZup/Linthra/issues/575) and
[cast-receiver-trust.md](cast-receiver-trust.md). Casting stays off in shipped
builds until that lands.

## The model in code

`CastMediaAccess` (`lib/core/services/cast/cast_media_access.dart`) is how a
source declares what casting one of its tracks hands over:

- **`delegation`** — a `scopedCapability` (a signed or otherwise scoped URL good
  for this item and nothing else), an `accountCredential` (the credential
  itself, because that is all the server accepts), or `none`.
- **`scope`** — how far it reaches if it is observed or kept: the single item, or
  the whole account.
- **`lifetime`** / **`revocableIndependently`** — whether the server bounds it,
  and whether the user can revoke this access without invalidating their session
  or changing their password.
- **`summary`** — a short sentence safe to print anywhere. It describes a URL's
  authority, never its contents.

Each resolver declares its own (`JellyfinCastMediaResolver.access`,
`SubsonicCastMediaResolver.access`), `CastMediaResolver.accessFor(track)` answers
without resolving or touching the network, and resolved `CastMedia` carries the
same answer. A source that declares nothing gets `CastMediaAccess.undeclared`,
which reads as account-level exposure: an omission shows up as an overstatement,
never as a quiet under-statement.

`test/core/services/cast/cast_media_access_test.dart` holds the model to that,
including the part that matters most — no source may claim a scoped capability
its server does not issue.

## What each server supports

| Source | How a stream request is authenticated | Scoped alternative available? | What a receiver ends up holding |
| --- | --- | --- | --- |
| **Jellyfin** | The session access token, in the URL's `api_key`. A receiver cannot send headers, so the credential has to be in the URL. | Not in the stable API: no per-item signed URL, no scoped download token, no server-side expiry to request. | An account credential that keeps working until the server revokes it. Signing out of Jellyfin in Linthra forgets the token here; it does not ask the server to invalidate it, so a receiver that kept the URL is unaffected until the user revokes that device in Jellyfin. |
| **Subsonic / Navidrome** | User name plus a salted token derived from the password, in the query, on every endpoint including streams. | Not through the Subsonic API. Navidrome has its own native API with shorter-lived tokens, but that is not the API Linthra speaks, and requiring it would break every other Subsonic server. | An account credential that does not expire on its own. It is derived from the password, so signing out here does not take it back either — only changing the password does. |
| **Plex** | The `X-Plex-Token` **header** — Linthra never puts it in a URL. Not wired for casting today. | Plex issues transient tokens, which bound the lifetime but are still account-scoped rather than per-item. | Would be a shorter-lived account credential, if casting ever routed through Plex. |
| **Audiobookshelf** | Bearer token. Not wired for casting today. | Not evaluated; it would need its own review before a cast resolver exists. | n/a |
| **On-device files** | Nothing: a receiver cannot reach a `file://` path, so these are not castable at all. | n/a | Nothing. |

So today, for both servers Linthra can cast from, the honest answer is
`accountCredential` / `account`. Saying otherwise — treating a token in a query
string as a capability, or adding a client-side expiry the server does not
enforce — would be inventing a restriction that only exists in our own code. A
receiver does not check it, and an attacker does not either.

Two things follow, and both are already true in the code:

- **Nothing else in the handoff carries the credential.** It rides on the
  `contentId` alone. Metadata does not carry it, `CastMedia.toString()` redacts
  the URL to scheme/host/path, the diagnostics API has no field for a token or a
  full URL, and error messages are generic by contract. Subsonic cover art is
  omitted for exactly this reason: it would carry the same credential for no
  playback benefit.
- **No broader credential is ever introduced as a fallback.** If a source cannot
  mint a castable URL, the track does not cast and the sheet says so. "Use the
  account credential instead" is not an error path.

## What would make this better

**Per-provider, upstream.** The change that actually helps is server-side: a
media endpoint that accepts a capability minted for one item, with an expiry and
independent revocation. For Jellyfin and Subsonic that is a server feature
request, not something a client can add. If either gains one, the work here is
small: declare `scopedCapability` on that resolver, mint it in the resolver, and
the model, tests and docs already have a place for it.

**Revoking on sign-out.** Signing out of a server in Linthra is local: the
credential is forgotten here, and the server is not asked to invalidate it. For
a handoff that has already happened, that is the difference between "the
receiver's copy stops working" and "it keeps working until the user goes and
revokes the device themselves". Jellyfin can revoke a session server-side, so
calling that on sign-out is a concrete, self-contained improvement — and a
change to sign-out behaviour for every user, not only those who cast, so it
belongs in its own change rather than riding along here. Subsonic has no
equivalent: its credential is the password.

**A media proxy on the device.** Built, not yet reachable from production
(`lib/core/services/cast/local_cast_media_proxy.dart`, behind the
`CastMediaRelay` interface `DefaultCastService` now requires). The app streams
from the server itself and re-serves the one item being cast over the LAN, so
the server credential never leaves the phone. What a receiver is given instead
is `http://<phone-lan-ip>:<port>/cast/<token>`, declared as
`CastMediaAccess.localRelay`.

How it answers the questions this option was parked on:

- **Authentication.** A receiver cannot send headers, so the proxy is guarded
  by the URL alone: a 256-bit token from `Random.secure()`, minted per item.
  The previous token is forgotten when the receiver first asks for the next
  item, the only reliable sign it has taken it (if handing it over fails, the
  new token is dropped instead, so the item still playing keeps working),
  every token also expires
  after a fixed lifetime (6 hours by default), and unknown or expired tokens get
  the same bare 404 without touching the server. Only `GET` and `HEAD` on
  exactly `/cast/<token>` are served.
- **Exposure.** It binds to the phone's private Wi-Fi/Ethernet IPv4 address on
  an OS-chosen port, not to every interface, so it is not offered on mobile data
  or a VPN tunnel. It speaks plain HTTP because the receiver has no way to trust
  a certificate the phone made up; what crosses the LAN is the token and the
  audio, and the token only reaches that item for that session.
- **What goes back.** Only media headers are relayed (`Content-Type`,
  `Content-Length`, `Content-Range`, `Accept-Ranges`, `ETag`,
  `Last-Modified`). `Range` is forwarded when it is a plain byte range, and
  `206` comes back as the server sent it, so seeking and buffering work; a
  `416` keeps its status and `Content-Range` but not its body, which a server
  may fill with diagnostics that include the credential. Any other upstream
  status becomes an empty `502`: no server body, no cookies, no auth
  challenge. So does a success that is a page rather than audio (a login
  screen behind a reverse proxy, a Subsonic error document), a redirect to
  another host (same-host redirects are followed, an http to https upgrade
  included, a downgrade at any hop refused), and a server that sends no headers within 20 seconds. A body
  that stops arriving for 30 seconds (while the receiver is still reading) is
  cut rather than left hanging. Only
  requests carrying a live token count as activity, so traffic without one
  cannot keep an orphaned relay alive. Nothing in the proxy logs.
- **Lifecycle.** The cast service starts it when a session starts and stops it
  when the session ends (disconnect, receiver drop, failed connect, dispose).
  Stopping closes the socket, drops every token and cuts transfers in flight.
  While a session is connected, the cast service asks the receiver for its
  status every few minutes and the receiver's reply keeps the relay awake, so a
  long pause can still be resumed. Its own idle stop (30 minutes with no
  request, no transfer in flight and no reply) catches a session that ended
  without telling it, including a receiver that died silently; the next track
  brings it back. Ending the session revokes the relay first, before waiting
  on the receiver to close. A token still expires 6
  hours after it was issued, so resuming the same item after a pause longer
  than that needs the track to be cast again. It runs in the main isolate, the
  same process as the background audio service.
- **Failure.** If it cannot start (no private LAN address, the port cannot be
  opened), the session is refused before the receiver is contacted and the
  sheet says casting is off for this session. If it cannot come back mid-
  session, the session ends. There is no path that hands the receiver the
  server URL instead.
- **Cost.** Every byte now goes server to phone to receiver, and the phone has
  to stay awake and on the network for the whole session. That is the price of
  keeping the credential home, and it is paid only while casting.
- **Open: Android and a paused cast.** On a user pause the audio service
  demotes its foreground service and releases its wake lock (#499), so a
  backgrounded, screen-off phone can have its process frozen with the relay in
  it. Resuming from the phone wakes it; a resume started from the receiver
  side while the phone is frozen stalls until the app runs again. Keeping the
  foreground service while a cast session is connected would close this, at a
  battery cost while casting; that trade-off is decided before the
  restoration, not here.

What it does not change: the phone to server hop is the same request local
playback already makes (for Jellyfin and Subsonic the credential is still in
that URL's query, over HTTPS when the server offers it), and the proxy is not a
substitute for authenticating the receiver. A token handed to a device nobody
authenticated is still handed to that device; it just cannot be reused as an
account credential, or at all once the session ends. Casting stays contained
until [#575](https://github.com/TheZupZup/Linthra/issues/575) is done.

**What is not on the table.** Client-side "restrictions" the server does not
enforce; sending a credential to a receiver that has not been authenticated
(regardless of scope); and weakening the model to keep a self-hosted deployment
working. Where a server simply cannot do better, the answer is to document the
limitation — as above — rather than pretend it away.

## If a scoped capability is ever added

Whatever mints it has to define, and test:

- **expiry** — short, server-enforced, and long enough only for the track;
- **revocation** — disconnecting or ending the session invalidates it, and the
  user can revoke it without touching their password;
- **cleanup** — nothing outlives the session: not in the catalog, not in a log,
  not in app state, not on disk;
- **redaction** — the same rule as today: the capability appears on exactly one
  field, and never in metadata, diagnostics, errors, or `toString()`.

And it still does not remove the receiver-authentication requirement.
