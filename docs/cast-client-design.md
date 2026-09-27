# The in-repo Cast client (design)

Casting is contained in shipped builds ([cast.md](cast.md#temporary-containment),
[#572](https://github.com/TheZupZup/Linthra/issues/572),
[#575](https://github.com/TheZupZup/Linthra/issues/575)). This page is the
design for the transport that replaces the `cast` package: how a connection
becomes an authenticated, media-ready session, what the client refuses, and
what has to be tested before any of it is trusted.

It builds on [cast-hardened-design.md](cast-hardened-design.md), which covers
why each layer exists. This page is about how the client is put together. It
does not change the containment, and nothing here is implemented yet.

## Status

| Item | State |
| --- | --- |
| Where the client lives | **Decided:** a narrow CastV2 client in this repository. The `cast` package is removed. |
| Crypto implementation | **Open.** Two options below, deliberately not chosen. Waiting on external review before anything is frozen or built. |
| Device matrix | **TBD, pending inventory.** No device scope is assumed on this page. |
| External review of the validator | **Pending.** The maintainer is asking the reporter directly through the advisory. |
| Containment | Unchanged. `CastContainment.isActive` stays `true` through every step here. |

## Why a client in this repository

The Cast surface Linthra uses is small: discover, connect, authenticate, launch
the Default Media Receiver, load, follow status, set volume, close. What the
current dependency (`cast 2.1.0`) would need to carry the authentication
exchange is not small:

- it only sends and receives JSON string payloads, and the device-auth exchange
  is a binary protobuf payload;
- the TLS socket is private to the package, so the peer certificate the proof
  must be bound to cannot be read;
- its message definitions are the pre-nonce shape (see
  [cast-hardened-design.md](cast-hardened-design.md#what-the-current-dependency-cannot-do));
- its framing assumes one socket read is one message, and it has no maximum
  frame size, no request correlation and no timeouts.

Three ways to get there were compared:

| | Contribute to `cast` | Maintain a reviewed fork | Client in Linthra |
| --- | --- | --- | --- |
| Time to a reviewable fix | Slow, and not ours to schedule | Medium | Fastest to review |
| Long-term maintenance | Tied to a single upstream maintainer; releases since 1.0 are dependency bumps | We carry a diff over nearly the whole package | All ours, but small |
| Attack surface we ship | Every upstream release needs a re-audit | Same, plus merge cost | Only what we use |
| Third-party dependency | Full | Nominal | `bonsoir` and `protobuf` only |

The changes reach almost every line of the package (framing, payload types,
socket access, message definitions, state handling), so a fork would be a
rewrite under someone else's name, and an upstream contribution could not be
waited on. Upstream issues or patches are still worth sending in parallel, as
goodwill, never as a dependency of the fix.

## What the client consists of

- **Discovery:** `bonsoir` directly (already a direct dependency). Discovery is
  not a trust boundary: a name and an address on the LAN prove nothing.
- **Framing and messages:** the `CastMessage` and device-auth definitions
  vendored under `third_party/` from Open Screen, with `upstream.sha256` and
  provenance, the same way the other vendored packages are handled. Generated
  Dart is committed with a regeneration script, and `protobuf` (dart-lang,
  already in the lockfile) becomes a direct dependency.
- **Trust anchors:** the Cast device roots listed in
  [cast-hardened-design.md](cast-hardened-design.md#the-trust-anchors), plus the
  separate **Cast CRL Root CA** that CRLs chain to (see
  [Revocation](#revocation)). Stored as DER with recorded digests; the CRL
  root's expected digest is fixed below, not taken from whatever file gets
  vendored.
- **Removed:** the `cast` package, from `pubspec.yaml`, the lockfile, the
  Flatpak generated sources and the dependency and license audits.

## The connection, step by step

One connection goes through these states, in this order only. Any message or
event not listed for the current state closes the connection and fails the
attempt.

| State | May send | May accept | Leaves when |
| --- | --- | --- | --- |
| `tls` | nothing | TLS handshake | Handshake completes and the peer certificate is captured, or timeout |
| `awaitingAuth` | one `DeviceAuthMessage{challenge}` (sender-0 to receiver-0, deviceauth namespace, binary payload) | exactly one device-auth response | Response verified, or anything else arrives, or timeout |
| `authenticated` | `CONNECT` to receiver-0 | nothing yet | `CONNECT` written |
| `launching` | one `LAUNCH` of `CC1AD845` with a fresh request id; heartbeat `PING` and `PONG` | heartbeat `PING` and `PONG`; `RECEIVER_STATUS` | A `RECEIVER_STATUS` answering that request id lists `CC1AD845`, or `LAUNCH_ERROR`, or timeout, or heartbeat loss |
| `ready` | `CONNECT` to the app's transport id, then media and volume commands; heartbeat `PING` and `PONG` | media and receiver status, heartbeat `PING` and `PONG`; media error replies (`LOAD_FAILED`, `LOAD_CANCELLED`, `INVALID_REQUEST`, `INVALID_PLAYER_STATE`) to our own request ids | `close()` (goes through `stopping`), error, heartbeat loss, or a `RECEIVER_STATUS` that no longer lists `CC1AD845` with the same transport id and session id |
| `stopping` | one receiver `STOP` for the app's session id, with a fresh request id; then `CLOSE` on both virtual connections | the `RECEIVER_STATUS` answering that request id; heartbeat | That status arrives, or a bounded wait (proposed 2 s) runs out; either way the socket is closed |
| `closed` | nothing | nothing | Terminal. A new attempt is a new connection object. |

Rules that go with the table:

- **Nothing but the challenge is written before authentication.** No
  `CONNECT`, no `GET_STATUS`, no `LAUNCH`. A receiver that talks first gets
  closed.
- **Readiness has exactly one source:** the `RECEIVER_STATUS` that answers our
  own `LAUNCH` request id, in the `launching` state, listing the Default Media
  Receiver with a non-empty transport id and session id. Both are taken from
  that entry and nowhere else: `CONNECT` and every media message are addressed
  to the transport id, and `STOP` names the session id. A status that arrives
  earlier, answers another request, lists only another app, or lists the app
  with either id missing or empty never produces readiness.
- **A rejected request is not a lost session.** In `ready`, a media error
  reply to one of our own request ids fails that request only (the track
  handoff or the control command reports it) and the session stays `ready`:
  the receiver may still be playing the previous item, and a pause or seek
  that races the end of a track gets `INVALID_PLAYER_STATE`. An error reply
  to a request id we never sent is a protocol error; a reply to one we sent
  whose deadline has passed is ignored, not treated as unknown (see the
  request deadlines below).
- **The app going away is session loss.** If a `RECEIVER_STATUS` in `ready`
  stops listing the Default Media Receiver, or lists it with a transport id or
  session id that is missing or differs from the ones taken at launch, the app
  we connected to is gone even if the platform connection is healthy. The session ends as if the receiver had dropped (the relay stops
  with it); nothing relaunches on its own.
- **Closing stops the app.** `close()` from `ready` sends the receiver a
  `STOP` for our session id before dropping the connection, so the Default
  Media Receiver does not keep playing on its own (the current adapter does the
  same through `endSession`). The wait for the answer is bounded, and the
  socket is closed whether or not it comes. A connection lost without
  `close()` sends nothing; the relay stopping is what cuts the media then.
- **Heartbeat both ways.** From the platform `CONNECT` on, the client sends a
  `PING` on a fixed cadence (proposed every 5 s) and answers every receiver
  `PING` with a `PONG`. Any inbound message counts as liveness; no inbound
  traffic for a fixed window (proposed 10 s, Chromium's values, to be tuned on
  devices) is heartbeat loss, which ends the session like a drop.
- **One challenge, one response.** A second response, a response before the
  challenge was written, or a device-auth error message fails the attempt.
- **Timeouts are per state** (proposed: TLS 10 s, auth reply 5 s, launch 10 s;
  to be tuned on devices). A timeout is a failure, never a slow success.
- **Every request in `ready` has a deadline** (proposed: `LOAD` 10 s, status
  and control 5 s). A reply after it is ignored, error replies included.
  Request ids are allocated in increasing order per connection, so the client
  keeps the highest id it has sent: a reply to an id at or below it that is
  no longer outstanding is late and ignored, however late, and only an id
  above it (never sent) is a protocol error. Nothing has to be remembered per
  expired request. At most one status request is outstanding at a
  time, so a periodic keep-alive never piles up entries. The session's
  liveness stays the heartbeat's job. What a timeout means depends on the
  request:
  - a status request that times out fails only itself;
  - a media control command (play, pause, seek) that times out changes no
    local state; the next media status is what the state follows;
  - a volume or mute command that times out changes no local state either,
    but media status does not carry device volume, so it is followed by one
    receiver `GET_STATUS`, and any valid `RECEIVER_STATUS` (late or
    unsolicited) updates the volume;
  - a `LOAD` that times out is ambiguous, since the receiver may have taken it.
    Nothing changes yet, the relay tokens included: one status request
    reconciles it. Only the new item counts as success. The previous item is
    handled as a rejection. An idle receiver with no previous item (the first
    handoff of a session) is a failed handoff: its token is revoked and the
    session stays `ready` with nothing playing. Anything else (idle after a
    previous item, an unrelated item, or no answer to that status request)
    means the receiver is in a state the client cannot account for, and the
    session ends.
- **Routing is checked on every inbound message:** protocol version
  `CASTV2_1_0`; a destination of our sender id, or `*` only for unsolicited
  status broadcasts, never for a reply to one of our request ids; and a source
  of `receiver-0` for the device-auth, connection, heartbeat and receiver
  namespaces, or the app's transport id for the media namespace (once `ready`).
  A message on the wrong route is a protocol error, whatever request id it
  carries.
- **Framing is strict:** a 4-byte big-endian length prefix, a fixed maximum
  frame size (proposed 64 KiB, to check against Open Screen's limit), reads
  reassembled across socket events, and a frame that does not parse closes the
  connection instead of throwing out of a listener.
- **Payload types are fixed per namespace:** binary for device-auth, string
  (JSON) for everything else. The wrong type is a protocol error.
- **JSON payloads are parsed and checked, never trusted:** invalid JSON, a top
  level that is not an object, an unknown `type`, or a field of the wrong
  shape (a non-integer `requestId`, a non-string `transportId`, and so on) is a
  protocol error that closes the connection in a controlled way. Numbers are
  checked for value as well as type: every numeric field must be finite and
  in its range (times and durations not negative and below a fixed bound,
  volume level between 0 and 1; request ids we allocate are positive
  integers, and a reply must carry one of ours, while `0` is accepted only on
  the unsolicited `MEDIA_STATUS` and `RECEIVER_STATUS` pushes the receiver
  sends on its own and never matches a request), so
  `1e999` or a negative position is a protocol error, not a value that throws
  later. Parsing happens inside the frame handler, so nothing throws out of
  the socket listener.
- **Every media status is checked against what we loaded.** Another sender
  can control the same receiver app, so a `MEDIA_STATUS` is only applied if it
  describes the item Linthra last had accepted (same content id and media
  session), whether it is an unsolicited push or the reply to one of our own
  status or control requests. (A `LOAD` reconciliation follows its own
  rules, above.) One for a different item, a new media session Linthra
  did not load, or media gone without the item finishing means another
  controller has taken over: the session ends and the relay stops, rather
  than keeping stale casting state and a live token.

## Device authentication

What is checked, in order. Every step is mandatory, and the first failure ends
the attempt.

1. **Capture the TLS peer certificate.** The receiver's TLS certificate is
   self-signed, so the TLS layer has to let the handshake complete
   (`onBadCertificate` returns true). That is only acceptable because the rest
   of this list decides trust, and nothing but the challenge is sent until it
   has. The certificate is read from `SecureSocket.peerCertificate` after the
   handshake, as exact DER (`X509Certificate.der`).
2. **Sanity-check the peer certificate.** Not yet valid, expired, or valid for
   more than 4 days is a refusal. Chromium applies the same 4-day limit and
   treats the X.509 validity as the expiry of the signature below. The
   evidence also bounds the connection: from the moment authentication
   succeeds, a timer runs to the earliest expiry among the peer certificate,
   the validated device chain and the CRL used, and the connection closes
   when it fires, in `authenticated`, `launching` or `ready` alike. Continuing after that is a new connection with a full
   authentication, never an extension of the old one.
3. **Send the challenge:** a 16-byte nonce from `Random.secure()`, fresh for
   this connection, and `hash_algorithm = SHA256`.
4. **Parse the response strictly.** Exactly one `AuthResponse`; a missing
   signature or leaf certificate, unknown fields where a value is required, or
   an error message instead of a response all fail. A missing nonce is left to
   step 5.
5. **Check the nonce echo:** presence and equality both follow the nonce
   policy (open, see
   [Strictness](#strictness-decided-after-the-device-matrix)).
6. **Validate the chain:** leaf plus intermediates up to a pinned Cast root, at
   the current time, within the profile in the crypto section.
7. **Check revocation** against the CRL (see [Revocation](#revocation)); where
   that CRL comes from, the device only or a shipped fallback, follows the CRL
   policy.
8. **Verify the signature** with the leaf's public key over the exact bytes
   `response_nonce || peer_certificate_DER`, RSASSA-PKCS1-v1_5, with the
   digests the digest policy accepts. `response_nonce` is the nonce the
   response carries, empty when it carries none. Under the strict nonce policy
   step 5 has already required it to equal ours, so this is our nonce; under a
   relaxed policy it is whatever the receiver echoed, as in Chromium.

The TLS handshake proves the receiver holds the private key of the peer
certificate. The signature proves a genuine Cast device vouched for that exact
certificate. Together they bind the proof to this TLS connection, which is why a
response recorded on another connection is useless.

### What Chromium actually does

Checked against Chromium `main`
(`components/media_router/common/providers/cast/channel/cast_auth_util.cc` and
`.../certificate/cast_crl.cc`), because the upstream defaults are the baseline
any stricter choice is measured against:

- **The nonce is not enforced.** A missing or mismatched echo only sets a flag,
  and the signature is verified over the nonce the *response* carries. The
  nonce is also a process-wide value rotated every 24 hours, not one per
  connection. Chromium relies on the peer-certificate binding for replay
  protection.
- **SHA-1 is accepted** and flagged.
- **The default CRL policy is `CRL_REQUIRED_WITH_FALLBACK`:** a device that
  sends no CRL, or an invalid one, is checked against a fallback CRL built into
  the browser, valid for 20 weeks after the build.

## Revocation

Cast CRLs are not X.509 CRLs. They are a protobuf `CrlBundle` of `Crl` entries,
each a `TbsCrl` (validity window, revoked public-key hashes, revoked serial
number ranges keyed by issuer key hash) signed by a certificate that chains to
the separate **Cast CRL Root CA**, not to the device roots. This corrects the
earlier statement in the hardened design that CRLs chain to the same roots.

The CRL root is pinned exactly, the same way the hardened design pins the
device roots:

| Root | Subject | Key | Valid until | SHA-256 of the DER |
| --- | --- | --- | --- | --- |
| Cast CRL Root CA | `C=US, ST=California, L=Mountain View, O=Google Inc, OU=Cast, CN=Cast CRL Root CA` | RSA 2048 | 2036-07-27 | `8b77c60291f9d62764613083f49750b1c5caac2d9efbe5a28edf301f9d84831d` |

Upstream copy: Chromium
`components/media_router/common/providers/cast/certificate/cast_crl_root_ca_cert_der-inc.h`
(self-signed, serial `0x99`, valid from 2016-08-01). The vendoring step checks
the vendored DER against this digest, and a CRL whose chain ends anywhere else
is refused.

That means a third parser (the CRL protobuf) and a second trust store. It also
means a policy decision the device matrix has to inform: require the device's
CRL, or ship a fallback CRL the way Chromium does, which then expires with the
app and needs refreshing through releases.

## Binding to the receiver and the session

- An authenticated identity belongs to one connection object. It holds the
  device id the user picked, the verified leaf certificate fingerprint, and
  nothing that outlives the connection.
- **The fingerprint is fixed:** SHA-256 over the device-auth leaf certificate
  exactly as received (DER, never re-encoded), written as lowercase hex with no
  separators, which `normalizeCastFingerprint` leaves unchanged. Changing any
  part of that later would read every pinned receiver as replaced, so it is
  part of the contract.
- **Trust follows the certificate, not the discovery name.** The device id
  comes from unauthenticated discovery, so it only says where to connect. The
  pin store also remembers every fingerprint the user has trusted, with the
  receiver name it was trusted under. A fingerprint seen for the first time is
  never trusted silently: the sheet asks the user to confirm a new receiver
  before the first cast to it. If that new fingerprint arrives under the name
  of a receiver already trusted, the sheet says plainly that it is a different
  device from the one used before. A trusted fingerprint showing up under a
  new device id is only recognised as the same receiver if the device matrix
  shows the device-auth leaf is unique per unit (two units of the same model
  included); until then it goes through the same confirmation. The store
  change and the confirmation land with the contract step, and the existing
  device-id store stays an open item until they do.
- **Forgetting forgets the certificate.** The sheet's "forget this device"
  removes the fingerprint from the trusted set together with every device id
  it has been seen under, not only the entry that was picked. The next
  connection to that receiver is a first use again, with the confirmation.
- Closing, timing out, reconnecting, changing receiver or replacing the session
  drops the identity with the connection. A new attempt starts from `tls` with
  a new nonce, and nothing from a previous attempt is consulted.
- **Pinning uses the device-auth leaf, not the TLS certificate.** The TLS
  certificate rotates within days, so pinning it would read as a changed
  receiver every few days. Whether the leaf is stable per device is to be
  confirmed on the matrix.
- The existing policy layer stays: `TrustGatedCastTransport` still checks that
  the identity matches the picked device and the session, and applies the pin
  store and its "forget this device" recovery.

## Contract changes

The current `CastReceiverAuthenticator.authenticate(device, CastSessionHandle)`
cannot be implemented honestly: by the time a `CastSessionHandle` exists, it
exposes neither the peer certificate nor a binary channel. So:

- authentication moves **into** the transport, between `tls` and
  `authenticated`;
- `connect()` takes a cancellation signal. Cancelling closes the socket from
  whatever state the attempt is in, writes nothing more (no `LAUNCH` after a
  cancel during auth), and makes `connect()` fail with a cancellation that
  `DefaultCastService` treats as stale. The service cancels its in-flight
  attempt on disconnect, on a receiver change, when the app is backgrounded
  (the lifecycle leaving the foreground, as required in
  [cast-receiver-trust.md](cast-receiver-trust.md)) and on dispose, instead of
  waiting for it to reach `ready` or time out. Backgrounding only cancels an
  attempt still connecting; a session already `ready` keeps playing;
- the transport only ever returns a `CastSessionHandle` for a connection in the
  `ready` state, carrying the verified identity. The launch's
  `RECEIVER_STATUS` has already been processed by then, so the handle keeps
  the current volume and replays it to every new volume listener; a service
  that subscribes after `connect()` returns still sees the receiver's volume
  and volume support straight away. Some receivers leave volume out of the
  launch status (the current adapter works around it), so if it is missing
  the transport sends one receiver `GET_STATUS` right after `ready`, and the
  handle replays its answer to listeners, early or late;
- `TrustGatedCastTransport` keeps its role as policy over that identity (match,
  pin, wording), and its tests move to the new shape. Its decision runs
  **inside** the transport, at a checkpoint in `authenticated` before the
  platform `CONNECT` and `LAUNCH`: the transport hands it the verified
  identity and writes nothing more until it answers. The checkpoint is
  bounded like every other state (proposed: 60 s, enough for the first-use
  confirmation), and just before writing `CONNECT` the transport rechecks the
  earliest expiry of the peer certificate, chain and CRL; if the evidence has
  expired while the user was deciding, the connection closes and the next
  attempt authenticates from scratch. A refusal closes the
  connection with no app launched on the receiver, so "no verified identity,
  no session" holds for the app launch too, not only for media. The gate's
  refusal messages change with it: today's "didn't send anything to it" is no
  longer true once the challenge has gone out, so every refusal from inside
  the handshake says only that no app, music or account details were sent.
- the handle also exposes the **local address of the receiver connection**
  (the connection's `address` getter, which in `dart:io` is this device's end
  of the connection; `remoteAddress` is the receiver). The on-device relay
  ([#678](https://github.com/TheZupZup/Linthra/pull/678)) binds to and
  advertises that address instead of picking an interface by preference, so a
  device on two networks (Wi-Fi and Ethernet on different subnets, for
  example) hands the receiver an address it can actually reach. The `cast`
  package keeps its socket private, which is why the relay cannot do this
  today.
- that changes the relay's lifecycle. Today `DefaultCastService` starts the
  relay, which picks and binds its address, **before** `connect()`, so a relay
  that cannot start refuses before the receiver is contacted. With the address
  only known once the handle exists, the start splits in two:
  1. before `connect()`, a preflight that at least one allowed LAN interface
     exists. Failing it is the same refusal as today, still before any
     receiver contact;
  2. after `connect()` returns a `ready` handle, and before any track is
     resolved or `LOAD` built, the relay binds to the handle's local address.
     If that address is not on an allowed interface, or the bind fails, the
     session is closed with its own message. The preflight's message promises
     that nothing was sent to the cast device, which is no longer true here:
     the receiver has seen TLS, device auth and `LAUNCH`. The new message
     only promises what holds, that no music and no account details were sent.

  A running relay is never rebound: each session binds its own.
- a rejected replacement `LOAD` keeps the cast as it was. Today
  `DefaultCastService._handOff` clears the casting track and reports idle,
  not casting, on any handoff failure, which hands control back to local
  playback while the receiver may still be playing the previous item. With
  error replies surfacing from the receiver, a rejected handoff keeps the
  previous casting state, status and relay token, and only reports that this
  track could not be cast. The same holds for a replacement that fails before
  any `LOAD`: a track that cannot be cast (an on-device file) or whose
  resolution fails, while another track is casting, leaves that track casting
  and only reports the message. Local playback never resumes while the
  receiver may still be playing.
- a missing track is a handoff too. When the current track becomes null (the
  queue cleared or ended), it is ordered like any other handoff: after a
  `LOAD` in flight settles, if the receiver has an accepted media session,
  the client sends a media `STOP` for it, revokes the relay tokens and reports idle, not casting. The
  session stays `ready` with nothing playing; if the `STOP` is rejected
  (`INVALID_REQUEST`, `INVALID_PLAYER_STATE`) or gets no answer by its
  deadline, the session ends. This is the one media command whose rejection
  is not an operation-level failure, because the receiver may still be
  playing. If there is no accepted media session (nothing was cast yet, or
  the only `LOAD` was rejected or reconciled to idle), no `STOP` is sent:
  any pending token is revoked and idle is reported. Linthra never reports
  that it stopped casting while the receiver may still be playing.
- handoffs are ordered, with at most one `LOAD` in flight. Each handoff takes
  a sequence number, and a newer track supersedes older ones. A superseded
  handoff that has not sent its `LOAD` never sends it and drops its token. A
  `LOAD` already sent is never ignored: its reply (or its reconciliation, on a
  timeout) settles what the receiver is playing first, and only then does the
  newest handoff send its own `LOAD`. So the state and the live tokens always
  match what the receiver last accepted.
- the relay learns about accepted `LOAD`s. Today it treats an item as playing
  only once the receiver first fetches it, and publishing a new item drops
  every token that is neither playing nor new. A `LOAD` accepted before its
  first fetch would then lose its token when the next track is published.
  So the service tells the relay when a `LOAD` is accepted, and the relay
  keeps that item's token alongside the new one until the next `LOAD`
  settles, whether or not it has been fetched yet.

## Keeping credential-bearing media behind the barrier

- `DefaultCastService` resolves a track only after `connect()` has returned a
  handle, and the handle only exists in `ready`, so resolution is already
  deferred until after authentication.
- With the on-device relay ([#678](https://github.com/TheZupZup/Linthra/pull/678)),
  `contentId` carries a per-item relay token, not the server URL.
- The transport refuses to build a `LOAD` (`CastLoadMessage.build`) unless the
  connection is `ready`. Tests inject a spy serializer and assert it was never
  called before readiness, on every failure path.

## Crypto: two options, not yet chosen

This section is self-contained so it can be reviewed on its own. **No option is
chosen, and the validator is not started, until it has been reviewed
externally.**

### Common to both options

Neither option removes this work, because no Dart library does it:

- **Path validation** for the Cast profile: leaf plus at most two
  intermediates, RSA-2048, pinned anchors, validity windows, `basicConstraints`
  (CA flag and path length, the Cast root asserts `pathlen:2`), key usage, the
  leaf not being a CA. Every extension's criticality is read, and a critical
  extension the validator does not implement is refused. The algorithm
  identifier inside `tbsCertificate` must equal the outer
  `signatureAlgorithm`, so policy and verification look at the same
  algorithm. Anything outside the
  profile is refused rather than interpreted.
- **Cast CRL parsing and verification** (protobuf, its own root).
- **Exact bytes:** signatures over certificates are checked against the
  `tbsCertificate` bytes exactly as received, never a re-encoding.
- **Canonical RSA signatures:** a signature must be exactly the modulus length
  in bytes and, as an integer, less than the modulus, checked before the
  public-key operation. Otherwise a leading-zero encoding or `s + n` would
  verify as the same signature. Option A enforces it itself; under Option B it
  has to be confirmed in the library or checked in front of it. Negative
  fixtures cover both aliases.
- **Fixtures generated at test time**, never real device certificates, with a
  negative fixture for every rejection reason.
- SHA-256 comes from `crypto` (dart-lang), already a dependency.

### Option A: no new runtime dependency, library as test oracle

- RSA PKCS#1 v1.5 verification written against the standard: the public-key
  operation with `BigInt.modPow`, then the expected encoded block is built and
  compared byte for byte, rather than parsing the decrypted padding.
- A strict DER reader for exactly the structures the profile needs, rejecting
  non-canonical encodings, indefinite lengths and trailing data.
- `pointycastle` and/or `asn1lib` only as `dev_dependencies`: every signature
  and certificate the tests check is also checked by the oracle (differential
  testing), and the two must agree.

| For | Against |
| --- | --- |
| Nothing new is shipped in the app itself | Every line is ours, including the DER reader, the historically bug-prone part |
| | The oracle still lands in `pubspec.lock`, so it still needs license audit entries (the audit covers dev dependencies) and regenerated pinned Flatpak sources, even though it never ships |
| The shipped surface is exactly the profile, so strictness is by construction | Correctness rests on our tests, the oracle and review, with no field-tested code underneath |
| Identical behaviour on Android and Linux | `BigInt.modPow` is not constant-time; believed irrelevant for public-key verification, to be confirmed by the reviewer |

### Option B: `pointycastle` at runtime

- `pointycastle` (publisher bouncycastle.org, MIT, depends on `collection` and
  `convert`) for RSA PKCS#1 v1.5 verification, and possibly its ASN.1 parser.

| For | Against |
| --- | --- |
| RSA verification from a widely used, maintained library | A large package shipped for a small use, a new runtime dependency to track in every audit |
| Less of our own code in the primitive | Whether its PKCS#1 verification compares the full encoded block, and whether its ASN.1 parser is strict DER and exposes raw TBS bytes, is not verified yet and would have to be before relying on it |
| | Does not validate paths or parse Cast CRLs, so the riskiest code is still ours |

### Questions for the reviewer

1. Is a hand-written strict DER reader for this narrow profile acceptable, or
   should parsing come from a library even if it is broader than needed?
2. Is encode-and-compare PKCS#1 v1.5 verification over `BigInt.modPow`
   acceptable, and is constant-time a concern for verification only?
3. Anything missing from the profile restrictions or the negative fixtures?
4. Revocation: require the device's CRL, or ship a fallback CRL like Chromium?

## Strictness (decided after the device matrix)

Each of these is stricter than Chromium, and each could refuse a real device.
None is decided until the matrix exists:

| Choice | Strict option | Chromium today | Risk if strict |
| --- | --- | --- | --- |
| Nonce echo | Must equal this connection's nonce | Not enforced; flagged | Older receivers may not echo |
| Digest | SHA-256 only | SHA-1 accepted, flagged | Older receivers may sign with SHA-1 |
| CRL | Device must send a valid one | Required, with a bundled fallback | Receivers that send none are refused, unless we ship a fallback |

Until then, the steps that touch these (nonce presence and equality, accepted
digests, where the CRL comes from) stay conditional, here and in the hardened
design. When a choice is made, the definitive steps and their tests are updated
together. Whatever is chosen is enforced in code and covered by tests; a relaxed
choice is written down with its reason, never left as a silent default.

## Negative tests

All with generated fixtures and a fake socket, so they run in CI.

- **Framing:** fragmented and coalesced frames, a length over the maximum, a
  truncated frame, a frame that is not a `CastMessage`, the wrong payload type
  for the namespace.
- **Payloads:** invalid JSON, a non-object top level, an unknown `type`, each
  field with the wrong type, and numbers that overflow (`1e999`), are negative
  where they cannot be, or fall outside their range, all closing the
  connection without an exception escaping the listener.
- **Routing:** a wrong protocol version; a message addressed to another
  sender; a broadcast answering one of our request ids; a platform message not
  from `receiver-0`; a media message from a transport id other than the app's.
- **Requests in `ready`:** a status request never answered fails at its
  deadline without ending the session; a late reply is ignored, and so is a
  late error reply (`LOAD_FAILED`, `INVALID_REQUEST`) to an expired id, even
  long after its deadline, while a reply to an id above the highest sent
  closes the connection; an unsolicited
  `MEDIA_STATUS` or `RECEIVER_STATUS` with `requestId` 0 is accepted, and a
  reply with 0 to one of our requests is not; a second
  keep-alive is not sent while one is outstanding; a `LOAD` that times out is
  reconciled by one status request (new item: success; previous item:
  rejection path; no answer: session ends), with no token revoked before that.
- **Session identity in `ready`:** a status with the same transport id but a
  missing or different session id ends the session, and no `STOP` is sent for
  the stale id; a `MEDIA_STATUS` for our item is applied, and one for another
  item or media session ends the session and stops the relay, whether it is
  unsolicited or the reply to our own status or control request.
- **Volume on a new handle:** a listener that subscribes after `connect()`
  returns gets the launch volume at once, and volume control is available
  without waiting for another receiver status; with a launch status that
  carries no volume, the follow-up receiver status is sent and its volume
  reaches early and late listeners.
- **Evidence expiry:** with a controlled clock, evidence expiring in
  `authenticated` or `launching` closes the connection just as it does in
  `ready`.
- **Sequencing:** any message before the challenge is sent; `RECEIVER_STATUS`
  before authentication; a second device-auth response; a response before the
  challenge; an unexpected namespace in each state; `CONNECT`/`LAUNCH`/`LOAD`
  never written before `authenticated`.
- **Device auth:** no response (timeout); malformed response; missing fields;
  device-auth error; missing, empty or altered nonce refused under the strict
  policy, and accepted under a relaxed one with the signature checked over the
  nonce the response carries (or none); a valid response for another
  challenge, refused under the strict policy (under a relaxed one it is the
  accepted altered-nonce case); a valid response recorded on a connection with
  a different peer certificate (replay), refused under either policy since the
  signature covers the peer certificate; a valid response from another
  receiver.
- **Peer certificate:** not yet valid, expired, lifetime over 4 days.
- **Chain:** untrusted root, incomplete chain, wrong order, expired
  certificate, leaf presented as a CA, path longer than the root allows, bad
  key usage, an unknown critical extension at every position, inner and outer
  signature algorithms that differ, malformed DER at every position, trailing
  data.
- **Signature:** over the wrong peer certificate, over the wrong nonce, by the
  wrong key, SHA-1 or unknown digest (per the strictness decision), altered by
  one bit.
- **Revocation:** a missing or invalid device CRL (expired, corrupt, chaining
  to another root than the pinned CRL root) is refused under the device-CRL
  policy, and checked against the bundled CRL under the fallback policy, which
  refuses too if the bundled CRL is itself expired or invalid; leaf revoked by
  key hash; intermediate revoked by serial range.
- **Session lifetime:** with a controlled clock, a `ready` session ends when
  the peer certificate, the chain or the CRL expires, whichever is first.
- **Trust checkpoint:** a pin mismatch or unknown device refused at the
  checkpoint writes no `CONNECT` or `LAUNCH`; with a controlled clock, a
  confirmation that outlasts the checkpoint bound, or that arrives after the
  evidence expired, closes the connection with no `CONNECT` or `LAUNCH`; a new fingerprint needs the
  user's confirmation, including under a known receiver's name; a trusted
  fingerprint under a new device id is recognised only with the per-unit
  uniqueness setting on; every refusal message promises only that no app,
  music or account details were sent.
- **Readiness:** a status answering another request id; a status listing only
  another app; the Default Media Receiver listed with a missing or empty
  transport id; `LAUNCH_ERROR`; launch timeout.
- **In `ready`:** `LOAD_FAILED`, `LOAD_CANCELLED`, `INVALID_REQUEST` and
  `INVALID_PLAYER_STATE` for our own request keep the session ready and fail
  only that operation; a volume timeout triggers one receiver status request, and the
  service keeps the previous casting state and token; the same replies for an
  unknown request id close it; a status without the app, or with a different
  transport id, ends the session and stops the relay.
- **Heartbeat:** `PING`s go out on the cadence in `launching` and `ready`;
  receiver `PING`s are answered; silence past the window ends the session.
- **Closing:** `close()` sends one `STOP` with our session id, then closes
  whether the answer comes or the bounded wait runs out; a lost connection
  sends nothing.
- **Cancellation:** cancelling in `tls`, `awaitingAuth`, `authenticated`
  (while the trust checkpoint waits for the user) and `launching` closes the
  socket, writes nothing further, and never lets a stale attempt reach
  `ready`; an approval delivered after the cancellation writes no `CONNECT`
  or `LAUNCH`; backgrounding the app does the same for an attempt in flight and
  leaves a `ready` session alone.
- **Handoff order:** a null track sends one media `STOP` after any `LOAD` in
  flight settles, revokes the tokens and reports idle (a `STOP` that is
  rejected or gets no answer ends the session); with no accepted media
  session, a null track sends no `STOP`, revokes any pending token and
  reports idle; two tracks in quick succession: the second `LOAD`
  waits for the first to settle; a first `LOAD` accepted while the second is
  rejected leaves the state and token on the first; a superseded handoff that
  never sent is dropped; a `LOAD` accepted before its first fetch keeps its
  token through the next publish and a rejected next `LOAD`; a replacement
  whose resolution fails, or that cannot be cast, leaves the current track
  casting.
- **Forget:** forgetting a receiver seen under several device ids removes the
  fingerprint and all of them; the next connection asks again.
- **`LOAD` reconciliation:** new item (success), previous item (rejection),
  idle on the first handoff (failed, session stays), idle after a previous
  item or an unrelated item (session ends).
- **Signatures:** a signature one byte longer with a leading zero, and one
  replaced by `s + n`, both refused.
- **Fingerprint:** a known leaf DER maps to its expected lowercase-hex SHA-256.
- **Status requests:** a media status request works with no known media
  session (asked without a session id), so the relay keep-alive keeps
  working while a LOAD is pending or after the receiver rejected it and kept
  the previous item.
- **Binding and session:** disconnect during auth; reconnect during auth; a
  receiver change during auth; identity from a replaced session never reaching
  the new one; state cleared after every one of these.
- **Credential gate:** the `LOAD` serializer spy is called zero times on every
  path that does not reach `ready`.
- **Relay binding:** no allowed interface refuses before any receiver contact;
  a handle whose local address is not on an allowed interface, or a bind
  failure after `ready`, closes the session with no track resolved and no
  `LOAD` built.

## Device matrix

**TBD, pending inventory.** The strictness choices above, leaf stability for
pinning, whether the device-auth leaf is unique per unit (checked on at least
two units of the same model), and timeout values all depend on it. Results go
to the advisory.

## Staging

Each step is its own draft PR, none of them relaxes the containment, and none
is reachable from production until the restoration:

1. This design.
2. Vendored message definitions, trust anchors and the CRL root, with
   provenance checks. No behaviour change.
3. The validator, chain, signature and CRL, standalone. **Blocked on the crypto
   decision and its external review.**
4. The client: framing, the state machine, device auth wired to 3. Not wired
   into production.

   Steps 3 and 4 build each open strictness choice (nonce presence and
   equality, accepted digests, device CRL or fallback) as an explicit setting
   with no default, both behaviours tested, because the matrix needs a working
   client to run. The matrix (step 5) picks the settings, and they are fixed,
   with the steps and tests updated, before step 6 lands.
5. Device matrix by hand, on the client from step 4. **Blocked on inventory.**
6. Contract changes: the transport returns only `ready` handles, the trust gate
   and its tests move to the new shape; `cast` removed.
7. The restoration, per the checklist in
   [cast-receiver-trust.md](cast-receiver-trust.md#restoration-checklist), as
   its own change and its own release.

## Open items

| Item | Owner | State |
| --- | --- | --- |
| Crypto option A or B | Maintainer, after external review | Pending |
| External review of the validator | Maintainer asks the reporter via the advisory | Pending |
| Device inventory for the matrix | Maintainer | Pending |
| Strictness choices (nonce, digest, CRL / fallback CRL) | After the matrix | Open |
| Maximum frame size and timeouts | Check against Open Screen, tune on devices | Open |
