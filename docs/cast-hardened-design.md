# How casting could actually work again (the hardened design)

Casting is switched off in shipped builds while a reported security issue is
resolved ([cast.md](cast.md#temporary-containment)).
[cast-receiver-trust.md](cast-receiver-trust.md) states the rule the app
enforces: no verified identity, no session, no media. This page is the answer to
the next question, the one that decides whether the feature ever comes back:
what would a receiver check have to be, concretely, for it to be worth trusting?

It is a design, not a plan of record. None of the protocol work exists yet,
nothing here changes the containment, and the restoration remains one reviewed
change ([#575](https://github.com/TheZupZup/Linthra/issues/575)). The two
app-side layers (3 and 5) are built, and the app does carry the pin store they
need, which is a preference rather than a path to a receiver: no shipped build
opens a cast socket. The report itself and the assessment of any specific
implementation stay in the private advisory.

## The short version

Five layers, each doing one job, and none of them a substitute for another:

| Layer | Question it answers | Where it stands |
| --- | --- | --- |
| 1. Transport | Is the channel private? | TLS exists today, and proves nothing about who is on the far end |
| 2. Device authentication | Is this a genuine Cast receiver? | Not implemented anywhere in the tree, and the package we depend on cannot express the modern challenge |
| 3. Device pinning | Is it *your* receiver, the same one as last time? | Built and tested (`cast_receiver_pinning.dart`), persistent in production, with the sheet's forget action |
| 4. Least privilege | If it is, how little can it be handed? | Modelled and documented ([cast-media-access.md](cast-media-access.md)) |
| 5. Fail-closed boundary | Does any doubt end in silence? | Built and tested (`trust_gated_cast_transport.dart`) |

Layers 3 and 5 are app-side policy, so they were landed ahead of the protocol
work: when a real handshake arrives it is reviewed on protocol grounds, not on
whether the plumbing around it is sound. Layer 2 is the missing one, and it is
the whole of the risk.

## Layer 1: the channel

A Cast receiver listens on TCP 8009 and speaks TLS with a self-signed device
certificate. Any client therefore has to accept a certificate it cannot chain to
anything, which is what the `cast` package does today:

```dart
// package:cast/socket.dart
final _socket = await SecureSocket.connect(
  host, port,
  onBadCertificate: (X509Certificate certificate) => true,
  timeout: timeout,
);
```

That line is not itself the bug. Accepting the certificate is unavoidable; the
question is what happens next. What matters is that the certificate is not
thrown away, because layer 2 binds to it. Dart gives us what we need:
`SecureSocket.peerCertificate` returns the peer's `X509Certificate`, and
`X509Certificate.der` is its exact DER encoding.

So layer 1's only job in this design is: connect, capture the peer certificate
DER, and trust nothing yet.

## Layer 2: prove it is a genuine receiver

Google Cast has a device-authentication exchange for exactly this, on the
`urn:x-cast:com.google.cast.tp.deviceauth` namespace. Every receiver carries a
manufacturer certificate chaining to a Google Cast root. The sender challenges
it, and the response is only meaningful because it is signed over the TLS
certificate the connection is actually using, which is what stops a relay in the
middle from forwarding somebody else's valid proof.

The exchange, following Chromium's and Open Screen's implementation
(`cast/sender/channel/cast_auth_util.cc`):

1. **Challenge.** Send `DeviceAuthMessage{challenge: AuthChallenge{sender_nonce,
   hash_algorithm: SHA256}}`, where `sender_nonce` is 16 bytes from a
   cryptographic RNG, fresh per connection.
2. **Response.** The receiver answers `AuthResponse{signature,
   client_auth_certificate, intermediate_certificate[], sender_nonce,
   hash_algorithm, crl}`.
3. **Echo check.** `response.sender_nonce` must equal the nonce we sent. This is
   the replay defence, and it has to be enforced, not merely compared.
4. **Chain.** Build the path `client_auth_certificate` +
   `intermediate_certificate[]` up to a pinned Cast root, and validate it at the
   current time: signatures, validity windows, `basicConstraints` (CA and path
   length), and key usage. The leaf must not be a CA and must be allowed to sign.
5. **Revocation.** The response carries a CRL, itself signed and chaining to the
   same roots. Check every certificate in the path against it.
6. **Signature.** Verify `signature` over the byte string
   `sender_nonce || peer_certificate_DER`, using the leaf's public key,
   RSASSA-PKCS1-v1_5 with SHA-256. The peer certificate is the one captured in
   layer 1, which is what ties the proof to this connection.
7. **Peer certificate sanity.** Reject a self-signed peer certificate with an
   implausibly long validity window, as upstream does.

Only if all seven hold is there an identity, and even then it is the identity of
*a* receiver.

### Where we would be stricter than upstream

Two of upstream's defaults are lenient for compatibility reasons that do not
apply to a music player shipping a fresh implementation:

- **SHA-1 signatures.** `AuthenticateChallengeReply` calls through with
  `enforce_sha256_checking = false`, so a receiver may answer with a SHA-1
  signature. We would require SHA-256 and refuse SHA-1. This is a compatibility
  bet, and the device matrix is where it gets settled: if a supported device
  cannot do SHA-256, that is a finding, not a reason to quietly relax.
- **CRL policy.** Upstream defaults to `kCrlOptional`, meaning a missing CRL is
  tolerated. We would require one, with the honest caveat below.

### What the current dependency cannot do

`cast 2.1.0` declares the namespace (`session.dart` has
`kNamespaceDeviceauth = 'urn:x-cast:com.google.cast.tp.deviceauth'`) but never
sends a challenge, and it could not express the modern one if it wanted to. Its
bundled `cast_channel.proto` carries the pre-nonce shape of the messages:

```proto
message AuthChallenge {
}

message AuthResponse {
  required bytes signature = 1;
  required bytes client_auth_certificate = 2;
  repeated bytes client_ca = 3;
}
```

No `sender_nonce`, no `hash_algorithm`, no `crl`. A challenge built from this
proto has no replay protection at all, because there is no nonce to echo. So the
protocol work is not "call the auth method that is already there": it starts
with the message definitions.

## The trust anchors

Two roots, both public, both currently used by Chromium and Open Screen:

| Root | Subject | Key | Valid until | SHA-256 of the DER |
| --- | --- | --- | --- | --- |
| Cast Root CA | `C=US, ST=California, L=Mountain View, O=Google Inc, OU=Cast, CN=Cast Root CA` | RSA 2048 | 2034-03-28 | `809af14700b3fe2611ad597eb1584d6354313b64ccdb3390f097fa3e5826d6ca` |
| Eureka Root CA | `C=US, ST=California, L=Mountain View, O=Google Inc, OU=Google TV, CN=Eureka Root CA` | RSA 2048 | 2032-12-12 | `caf6d1e37b532203e01a76bf07187bb731ccd38801565ab2211a2c0ab7f3bc46` |

Both are self-signed with `sha1WithRSAEncryption`, which is not a problem: a
pinned anchor's own signature is never verified, only its public key is used. The
Cast root asserts `CA:TRUE, pathlen:2`, which bounds the chain to at most two
intermediates and is worth enforcing rather than assuming.

They would live in the repository as DER blobs with their digests recorded, the
same provenance discipline `scripts/check_vendored_packages.sh` already applies
to `third_party/`. Upstream copies are
`cast/common/certificate/cast_root_ca_cert_der-inc.h` and
`eureka_root_ca_der-inc.h` in Open Screen. Two operational notes that belong in
the design rather than in a surprise five years from now: anchors expire (2032
and 2034), and Google can add roots. A pinned store needs an owner, a review
step when it changes, and a build that fails loudly rather than a device that
stops working mysteriously.

## Doing the cryptography

This is the part to be honest about: there is no pure-Dart RFC 5280 path
validator to depend on. `pointycastle` (MIT, pure Dart, no native code) has RSA
PKCS#1 v1.5 verification and the digests; `asn1lib` (no dependencies) parses DER.
Neither builds or validates a certificate path. That code would be ours.

Two routes were considered.

**Route A, one pure-Dart validator, used on every platform.** Recommended.
Linthra ships Android and Linux from one codebase, and the F-Droid and Flatpak
builds have to stay free of proprietary components, so a single implementation
that behaves identically everywhere is also the only one that gets reviewed once
rather than twice. The saving grace is that the Cast case is not general PKI: a
leaf plus at most two intermediates, RSA-2048 throughout, one signature scheme,
two pinned anchors, no name constraints, no policy mapping, no AIA fetching, no
OCSP, no hostname matching. Written to that shape and refusing anything outside
it, the validator is a few hundred lines that a reviewer can hold in their head.

**Route B, the platform's own validator.** On Android, `CertPathValidator` with a
`TrustAnchor` per pinned root and `Signature.getInstance("SHA256withRSA")`; on
Linux, OpenSSL through `dart:ffi`. Mature code doing the risky part, which is
genuinely attractive. It was not chosen because it means two implementations plus
a platform channel, a security property that differs by platform, and a Flatpak
build whose behaviour depends on the runtime's libcrypto. Worth revisiting if
route A's validator turns out to be harder to get right than it looks: that would
be a real finding, and this is written down so the alternative is not
rediscovered from scratch.

Whichever route, the review load is the same and it is the highest in this
document. It gets fixture chains generated at build time, not committed test
certificates that expire, and negative fixtures for each rejection reason.

## Where the client code lives

Not a fork of `cast 2.1.0`. The changes needed (new message definitions, a
mandatory challenge, peer certificate capture, binding the session to the proof)
reach almost everything the package does, while the surface Linthra actually uses
is small: discover, connect, authenticate, load, status, volume, disconnect. A
narrow in-repo client implementing exactly that, with authentication mandatory
rather than optional, is less code to review than the diff against the package
would be.

Upstream material we would take verbatim, principally the `.proto` definitions,
goes under `third_party/` with `upstream.patch` and `upstream.sha256`, the
pattern `third_party/just_audio_media_kit` already follows and CI already checks.

An upstream contribution to the package is worth doing in parallel: it helps
every other app using it. It is not worth waiting on, because the restoration
cannot depend on somebody else's release schedule.

## Layer 3: it has to be *your* receiver

This is the layer that is easy to skip and the one that most closely matches what
users assume is happening.

Device authentication proves the peer holds a genuine Cast certificate. It does
not say which genuine receiver it is. Discovery is a friendly name and an address
on a LAN, both unauthenticated, so another real Cast device (a neighbour's, a
guest's, one plugged in by somebody else) can answer to a familiar name and pass
the handshake completely honestly. Layer 2 alone would hand it the stream.

So the fingerprint of the certificate a device proved itself with is recorded the
first time it is used, and required to match every time after
(`lib/core/services/cast/cast_receiver_pinning.dart`, enforced in
`TrustGatedCastTransport`). The rules that make it worth having:

- **A store that cannot answer is not a first use.** A read that throws or hangs
  refuses the connection rather than re-pinning, because otherwise breaking the
  store is a way to erase the check.
- **A failed write refuses too, and the write is read back.** Handing out a
  session that was never recorded would leave the entry unpinned, and the next
  receiver to answer, whichever one that is, would become the pin. Reading back
  also settles the race where two connections reach an empty pin together: the
  store keeps the first, and the second finds out it is not the receiver that got
  recorded.
- **A mismatch never overwrites.** Replacing a pin is `forget()`, behind a
  deliberate user action, never something the trust path does to recover.
- **An empty fingerprint is a refusal**, not a pin that matches everything.
- **Formatting is not a security decision.** Case, colons and whitespace are
  normalised before comparing, so a cosmetic change in an authenticator cannot
  read as a swapped device. Deliberately not `-` or `_`: those are digits of a
  base64url digest, and dropping them could make two different fingerprints
  compare equal. Anything outside that list fails the comparison, which is a
  refusal the user can see.

The user-facing half is a distinct failure kind
(`CastTrustFailureKind.changedReceiver`) with its own message, because unlike
every other refusal this one has an action attached: if you really did replace
the speaker, forget it and connect again.

Both follow-ons this layer needed have landed, ahead of the protocol work and
without touching the containment.

The store is persistent in production
(`lib/data/repositories/shared_preferences_cast_receiver_pin_store.dart`). An
in-memory store makes every launch a first use, so a swapped receiver is noticed
for one session and forgotten by the next; pins now outlive the app. It is
deliberately the one `shared_preferences` store in the repository that throws
rather than degrading to a default. Everywhere else, unreadable storage costing
the user a default tab or a default theme is the right trade; here "I can't read
the pin" resolving to "this device has no pin" would re-pin whichever receiver
answered, which is the erase-the-check path the rules above exist to close. One
key per device, keyed by a digest of the device id (for shape, not secrecy:
discovery returns whatever a receiver advertises, and nothing about a device id
should decide what a preference key looks like).

The sheet carries the affordance the `changedReceiver` message points at, and
getting there needed one more fix than expected: the sheet used to replace its
device list with an empty state whenever the service reported an error, so a
user told to "forget it in the cast list and try again" was looking at a screen
with no cast list on it. A refusal now keeps the list it was caused from, which
is both the retry and the recovery. "Forget this device" sits behind a
confirmation that says what it costs, is offered only where there is a pin to
drop, and is not offered for the connected device (that session already proved
itself, so dropping its pin would change nothing now and read as if it had). A
pin store that cannot answer still gets the menu item: whether the recovery is
drawn is a UI question, not a trust one, and `TrustGatedCastTransport` refuses on
that same throw regardless.

What is left for the restoration is to hand the same store to
`TrustGatedCastTransport`, which is step 7 below.

## Layer 4: hand over as little as possible

Unchanged from [cast-media-access.md](cast-media-access.md), and worth restating
because it is the layer people reach for first: for both servers Linthra can cast
from, what a receiver ends up holding is an account credential, because neither
Jellyfin nor Subsonic issues a per-item capability. Narrowing that is real
defence in depth and it is not a substitute for layers 2 and 3. A scoped URL
handed to a device nobody authenticated is still a handoff to an unknown device.

## Layer 5: any doubt ends in silence

Also unchanged, and already in the tree: `TrustGatedCastTransport` hands out a
session only after the receiver authenticated, the identity matches both the
device the user picked and the session it will use, and the pin agrees. Every
failure closes the session with a bounded cleanup, every outbound operation
re-checks, trust ends with the connection it was proved over, and the gate owns
the wording so nothing from a handshake can reach the screen.

## What this design does not fix

Written down deliberately, because a design that only lists its strengths is not
one you can review:

- **First use is still first use.** Pinning catches a device that changes; it
  cannot catch an impostor that was there the very first time. Requiring the user
  to confirm a device the first time it is used narrows the window, and does not
  close it.
- **The CRL arrives from the device being checked.** A receiver that wants to
  hide its own revocation can simply not send one. Requiring a CRL turns that
  into a refusal rather than a silent pass, which is the best a client can do
  offline, and it is not the same as fresh revocation data.
- **A genuine certificate on compromised hardware still passes.** Device
  authentication attests the manufacturer, not the current state of the device.
- **Denial of service stays available.** Anything on the LAN can stop casting
  from working. That is the acceptable failure: this whole design is built so
  that the failure mode is silence, not a stream going somewhere unknown.
- **Nothing here reduces what a credential-bearing URL is worth once handed
  over.** That is layer 4's problem, and it is a server-side one.

## Getting there

Staged, so that each step is reviewable and none of them relaxes the containment:

1. **Vendor the protocol definitions and the trust anchors**, with provenance
   checks. No behaviour change.
2. **The validator**, standalone: chain building and validation against pinned
   anchors, CRL handling, signature verification. Reviewed on its own, with
   generated fixtures and negative cases. Not reachable from the app.
3. **The Cast client**, narrow, with the challenge mandatory. Still not wired
   into production.
4. **The authenticator** implementing `CastReceiverAuthenticator` on top of 2 and
   3, plugged into the existing gate. Still not wired into production.
5. ~~**A persistent pin store and the sheet's forget affordance.**~~ Done, see
   layer 3.
6. **Device matrix by hand**, results to the advisory.
7. **The restoration itself**, per the checklist in
   [cast-receiver-trust.md](cast-receiver-trust.md#restoration-checklist): the
   production wiring, `CastContainment.isActive`,
   `scripts/check_cast_containment.py` and
   `scripts/verify_release_containment.py` all in one change, then its own
   release.

Steps 1 through 5 can land while casting stays off, which is the point of
splitting them: by the time the containment is lifted, everything except the
device testing has already been reviewed on its own terms.

## Tests

The app-side boundary is covered today
(`test/core/services/cast/trust_gated_cast_transport_test.dart`), including the
pinning cases above, along with the persistent store's own rules
(`test/data/repositories/shared_preferences_cast_receiver_pin_store_test.dart`:
a pin survives a new instance, `remember` never replaces one, an unreadable
entry throws rather than reading as a first use) and the sheet's recovery
(`test/features/player/cast/cast_devices_sheet_test.dart`). The protocol side
arrives with the implementation and owes, at minimum:

- a response with a missing, empty, or altered `sender_nonce`;
- a valid response replayed from another connection or another challenge;
- a signature over the wrong peer certificate, which is the relay case;
- an untrusted root, an expired certificate, a leaf presented as a CA, a chain
  longer than the anchor's path length, a chain in the wrong order;
- a SHA-1 signature, and an unknown hash algorithm;
- a missing CRL, a CRL that does not verify, and a CRL revoking a certificate in
  the path;
- a receiver that completes TLS and never answers the challenge, and one that
  answers after the timeout;
- malformed DER at every position, including truncated and oversized inputs.

All of it with generated fixtures. Never with real device certificates, and never
with anything from the private report.
