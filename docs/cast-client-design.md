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
  [Revocation](#revocation)). Stored as DER with recorded digests.
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
| `ready` | `CONNECT` to the app's transport id, then media and volume commands; heartbeat `PING` and `PONG` | media and receiver status, heartbeat `PING` and `PONG`; media error replies (`LOAD_FAILED`, `LOAD_CANCELLED`, `INVALID_REQUEST`) to our own request ids | `close()` (goes through `stopping`), error, heartbeat loss, or a `RECEIVER_STATUS` that no longer lists `CC1AD845` with the same transport id |
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
  handoff reports it) and the session stays `ready`: the receiver may still be
  playing the previous item. An error reply to a request id we never sent is a
  protocol error.
- **The app going away is session loss.** If a `RECEIVER_STATUS` in `ready`
  stops listing the Default Media Receiver, or lists it with another transport
  id, the app we connected to is gone even if the platform connection is
  healthy. The session ends as if the receiver had dropped (the relay stops
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
- **Framing is strict:** a 4-byte big-endian length prefix, a fixed maximum
  frame size (proposed 64 KiB, to check against Open Screen's limit), reads
  reassembled across socket events, and a frame that does not parse closes the
  connection instead of throwing out of a listener.
- **Payload types are fixed per namespace:** binary for device-auth, string
  (JSON) for everything else. The wrong type is a protocol error.

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
   treats the X.509 validity as the expiry of the signature below.
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

That means a third parser (the CRL protobuf) and a second trust store. It also
means a policy decision the device matrix has to inform: require the device's
CRL, or ship a fallback CRL the way Chromium does, which then expires with the
app and needs refreshing through releases.

## Binding to the receiver and the session

- An authenticated identity belongs to one connection object. It holds the
  device id the user picked, the verified leaf certificate fingerprint, and
  nothing that outlives the connection.
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
  attempt on disconnect, on a receiver change and on dispose, instead of
  waiting for it to reach `ready` or time out;
- the transport only ever returns a `CastSessionHandle` for a connection in the
  `ready` state, carrying the verified identity;
- `TrustGatedCastTransport` keeps its role as policy over that identity (match,
  pin, wording), and its tests move to the new shape.
- the handle also exposes the **local address of the receiver connection**
  (the socket's own `address`). The on-device relay
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
  track could not be cast.

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
  extension the validator does not implement is refused. Anything outside the
  profile is refused rather than interpreted.
- **Cast CRL parsing and verification** (protobuf, its own root).
- **Exact bytes:** signatures over certificates are checked against the
  `tbsCertificate` bytes exactly as received, never a re-encoding.
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
- **Sequencing:** any message before the challenge is sent; `RECEIVER_STATUS`
  before authentication; a second device-auth response; a response before the
  challenge; an unexpected namespace in each state; `CONNECT`/`LAUNCH`/`LOAD`
  never written before `authenticated`.
- **Device auth:** no response (timeout); malformed response; missing fields;
  device-auth error; missing, empty or altered nonce refused under the strict
  policy, and accepted under a relaxed one with the signature checked over the
  nonce the response carries (or none); a valid response for
  another challenge; a valid response recorded on another connection (replay);
  a valid response from another receiver.
- **Peer certificate:** not yet valid, expired, lifetime over 4 days.
- **Chain:** untrusted root, incomplete chain, wrong order, expired
  certificate, leaf presented as a CA, path longer than the root allows, bad
  key usage, an unknown critical extension at every position, malformed DER at
  every position, trailing data.
- **Signature:** over the wrong peer certificate, over the wrong nonce, by the
  wrong key, SHA-1 or unknown digest (per the strictness decision), altered by
  one bit.
- **Revocation:** missing CRL, CRL not chaining to the CRL root, expired CRL,
  leaf revoked by key hash, intermediate revoked by serial range.
- **Readiness:** a status answering another request id; a status listing only
  another app; the Default Media Receiver listed with a missing or empty
  transport id; `LAUNCH_ERROR`; launch timeout.
- **In `ready`:** `LOAD_FAILED`, `LOAD_CANCELLED` and `INVALID_REQUEST` for our
  own request keep the session ready and fail only that handoff, and the
  service keeps the previous casting state and token; the same replies for an
  unknown request id close it; a status without the app, or with a different
  transport id, ends the session and stops the relay.
- **Heartbeat:** `PING`s go out on the cadence in `launching` and `ready`;
  receiver `PING`s are answered; silence past the window ends the session.
- **Closing:** `close()` sends one `STOP` with our session id, then closes
  whether the answer comes or the bounded wait runs out; a lost connection
  sends nothing.
- **Cancellation:** cancelling in `tls`, `awaitingAuth` and `launching` closes
  the socket, writes nothing further, and never lets a stale attempt reach
  `ready`.
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
pinning, and timeout values all depend on it. Results go to the advisory.

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
