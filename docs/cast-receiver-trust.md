# Receiver trust (what has to be true before casting comes back)

Casting is switched off in shipped builds while a reported security issue is
resolved ([cast.md](cast.md#temporary-containment)). This page is the public
half of what restoring it requires: the trust model, the contract the code
already enforces, the implementation choices on the table, and the tests that
have to pass. It tracks
[#575](https://github.com/TheZupZup/Linthra/issues/575).

The report itself, the assessment of any specific implementation, and the
protocol-level evidence stay in the private security advisory until coordinated
disclosure. If you are picking this work up, ask for advisory access rather than
reconstructing the details from the code or from this page.

## The trust model

Casting means telling a device on the network to fetch a stream and play it. Two
separate questions decide whether that is safe, and answering one does not answer
the other:

1. **Who is the receiver?** A name and an address on a LAN are not an identity.
   mDNS discovery is unauthenticated: anything on the network can answer to a
   friendly name. Until the device proves cryptographically that it is the one
   the user picked, the app is talking to "whatever answered".
2. **What does the receiver get?** Whatever URL is handed over carries some
   authority on the user's music server. Narrowing that is
   [#576](https://github.com/TheZupZup/Linthra/issues/576) and
   [cast-media-access.md](cast-media-access.md) — an additional layer, never a
   substitute for this one. A scoped URL handed to an unauthenticated device is
   still a handoff to an unknown device.

So the rule the app enforces is: **no verified identity, no session, no media.**

Google Cast has a device-authentication step for exactly question 1: receivers
carry a manufacturer certificate chaining to a Cast root, and a sender
challenges the device over the `deviceauth` namespace and verifies the response
against that chain and the connection it arrived on. A sender that opens a
connection and starts sending media without completing that step has not
identified anything. Whether a given implementation does it, and what it does
with the result, is what the advisory review covers.

## What is already in the tree

Two pieces of the restoration are built and tested now, deliberately ahead of
the implementation choice, so that reviewing the eventual transport is about the
protocol rather than about the app's plumbing:

- **`CastReceiverAuthenticator`** (`lib/core/services/cast/cast_receiver_trust.dart`)
  — the contract. It is handed the session to check, and returns a
  `CastReceiverIdentity` naming both the device and that connection, or throws.
  The connection half matters: Cast's device authentication is a challenge
  answered on a connection, so a proof gathered anywhere else describes a
  different conversation than the one the media would go to. An inconclusive
  check (timeout, dropped connection, an implementation that throws something
  unexpected) is a failure, never a pass. The shipped implementation is
  `UnverifiedCastReceiverAuthenticator`, which refuses every receiver, because
  nothing here can yet prove one.
- **`CastReceiverPinStore`** (`lib/core/services/cast/cast_receiver_pinning.dart`)
  — the layer authentication does not cover. A Cast handshake proves the peer is
  *a* genuine receiver, never that it is the one the user meant: discovery is a
  friendly name on a LAN, so another real Cast device can answer to it and pass
  the handshake honestly. So the fingerprint a device first proved itself with is
  recorded and required to match afterwards, a store that cannot answer refuses
  rather than re-pins, a mismatch never overwrites, and replacing a pin is an
  explicit `forget()` by the user. Production stores pins in
  `shared_preferences` (`SharedPreferencesCastReceiverPinStore`), so a swapped
  receiver is caught across restarts rather than within one session, and that
  store throws instead of degrading: unreadable storage must not read as "this
  device has no pin". The in-memory default remains what an unconfigured app
  gets, chosen so a missing store shortens the memory rather than removing the
  check.
- **`TrustGatedCastTransport`** (`lib/core/services/cast/trust_gated_cast_transport.dart`)
  — the readiness boundary. It wraps a `CastTransport`: a session is only handed
  out after the receiver authenticated *and* the identity matches both the
  device the user picked and the session it will use; any failure closes the
  session (with a bounded cleanup, so an unresponsive receiver cannot hold the
  refusal back); every outbound operation — the media handoff and the transport
  controls alike — refuses again on its own; and trust ends with the connection
  it was proved over, whether that is a close from here or the receiver
  dropping. Only teardown stays ungated. The gate also owns the wording: a
  refusal keeps its `CastTrustFailureKind` and nothing else, so nothing an
  authenticator wrote into a message — possibly built from what the receiver
  said — can reach the sheet. `DefaultCastService` surfaces that message rather
  than a generic "couldn't connect", so a security refusal does not read as a
  flaky network.

Neither is wired into production, and neither restores casting. Containment
still comes first in every path: the gate authenticates over a connection the
delegate opened, so a contained transport refuses before trust is even asked
about — there is a test for exactly that, so the gate cannot become a second way
to reach a device.

`test/core/services/cast/trust_gated_cast_transport_test.dart` covers the
negative cases end to end: a refusal, a device that authenticates as a different
device, a proof made over another connection, an authentication that never
finishes, a session that drops or dies mid-handshake, a session that drops in
the gap between the check and the handoff, and a receiver that will not close
cleanly, will not close at all, or throws on the way. An authenticator that
throws counts either way — before or after it returns its future — and a
readiness error becomes a clean "not ready" rather than an unhandled error
escaping into the service. Each case ends with the session closed and nothing
loaded, and no refusal message carries anything from the handshake.

## Choosing an implementation

The restoration needs something that actually performs the handshake.
[cast-hardened-design.md](cast-hardened-design.md) works that through in detail:
the device-authentication exchange step by step, the two pinned Cast roots with
their digests, why the current dependency's protocol definitions cannot express
the modern challenge at all, where the certificate-path validation would come
from, and what the design still does not fix. The options it weighs, in summary:

| Option | Why it might work | What it costs |
| --- | --- | --- |
| **Auditable fork of the pure-Dart Cast client** | Keeps the current architecture: no Google Play Services, no proprietary SDK, so F-Droid and sideloaded builds stay identical. The protocol code already exists. | We own the crypto review, the pinned Cast root certificates, and the maintenance. Fork provenance and update path have to be part of the review. |
| **Upstream contribution to the existing package** | Same as above, and the fix helps every other app using it. | Depends on upstream's timeline, which the restoration cannot. Reasonable to pursue in parallel, not to wait on. |
| **Narrowly scoped replacement** | Only the pieces Linthra uses (discover, connect, authenticate, load, status, volume), with authentication mandatory rather than optional, and a much smaller surface to review. | The most work up front, and the protocol details have to be right. |
| **Google's Cast SDK via a platform plugin** | Google maintains the trust model. | Requires Play Services and proprietary components: it would break the F-Droid build and the "same app everywhere" property. Not acceptable for Linthra as it stands. |

Whichever is chosen, the review has to cover: the trust anchors used to validate
a receiver certificate and how they are updated; protocol compatibility with
supported devices; the dependency's provenance (publisher, pinning in
`pubspec.lock`, and — if vendored — placement under `third_party/` with the
license audit in [dependency-license-audit.md](dependency-license-audit.md));
and which platforms it actually supports.

## Tests the restoration has to pass

**Negative, in CI, with controlled fixtures.** Never with real credentials, real
device certificates, or anything pulled from the private report:

- a receiver presenting no certificate, an untrusted chain, an expired
  certificate, or a chain for a different device;
- a valid response replayed from another handshake or another challenge;
- a receiver that completes the TLS connection and then never answers the
  challenge;
- a receiver that changes identity between selection and handoff, or a
  connection that is swapped underneath a pending session;
- cancellation: the user backing out, picking another device, or the app being
  backgrounded mid-handshake.

The boundary tests already in the tree are the app-side half of this list; the
protocol-side half arrives with the implementation.

**Positive, on real hardware.** A device is the only thing that proves
interoperability: at least one Chromecast-class dongle, one Cast-enabled speaker,
and one Cast-enabled TV, covering connect, handoff, transport controls, volume,
disconnect, and the receiver dropping mid-playback. Results go in the advisory,
not in a public PR description.

## Restoration checklist

Restoring casting is one reviewed change, not a revert. It has to:

- [ ] land a real `CastReceiverAuthenticator` and the transport that performs the
      handshake, reviewed in the advisory;
- [ ] put the trust gate in front of the live transport in the production
      wiring, with no path around it and no runtime flag that skips it;
- [x] ship a persistent `CastReceiverPinStore` and the cast sheet's "forget this
      device" action, so pinning survives a restart and a genuinely replaced
      receiver has a way back that is not a bypass. Landed ahead of the
      restoration: the pins a restored feature checks have to predate the
      release that restores it;
- [ ] flip `CastContainment.isActive` and update the production wiring, the
      transport guards, `scripts/check_cast_containment.py` and
      `scripts/verify_release_containment.py` together — the containment
      markers describe a contained build, so after restoration they describe
      nothing;
- [ ] pass the negative tests above in CI and the device matrix by hand;
- [ ] re-check the media handoff against
      [cast-media-access.md](cast-media-access.md), so the restored path does not
      quietly widen what a receiver is given;
- [ ] offer the reporter a review through the advisory before production
      availability returns;
- [ ] ship as its own release, separate from the containment release recorded in
      [release-artifact-verification.md](release-artifact-verification.md).

Until every box is ticked, the safeguard stays. A partially reviewed
restoration, a debug-only bypass, or a "temporarily re-enable to test on a
device" flag are all the same thing as shipping it.
