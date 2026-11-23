import 'package:flutter/foundation.dart';

import '../../models/cast_state.dart';
import 'cast_transport.dart';

/// Why a receiver was not trusted. Every value means the same thing to the app —
/// no session, no media — and they exist so the reason can be told apart in
/// tests and in a calm, secret-free note to the user.
enum CastTrustFailureKind {
  /// Nothing here can vouch for this receiver: no verified transport is wired,
  /// so authentication is not merely failing, it is not implemented. This is the
  /// state Linthra ships in today, and it is deliberately a failure rather than
  /// a skip.
  unsupported,

  /// The receiver answered and the answer was not good enough: an untrusted or
  /// malformed certificate chain, a bad signature, a response for a different
  /// challenge.
  rejected,

  /// The receiver proved *an* identity, but not the one the user picked. A
  /// device that authenticates as some other device is exactly the case a
  /// handoff must not survive.
  identityMismatch,

  /// The receiver proved a genuine identity, and it is not the one this device
  /// presented last time. Authentication says "a real Cast receiver", never "the
  /// real Cast receiver you meant": a second genuine device answering to a
  /// familiar name passes the handshake honestly. This is the one outcome a user
  /// can clear themselves, by forgetting the device, so it is worth telling
  /// apart from a mismatch the app caught on its own.
  changedReceiver,

  /// Authentication never finished: the session ended underneath it, the user
  /// moved on, or it ran out of time. An unfinished check is a failed check.
  incomplete,
}

/// A typed, user-facing failure raised while establishing receiver trust.
///
/// Security invariant, identical to [CastMediaException]: [message] must NEVER
/// carry a certificate, a challenge, a nonce, a token, or anything else from the
/// handshake — only generic text the cast sheet can show. What actually went
/// wrong belongs in the private advisory and in test expectations, not on a
/// user's screen or in a log.
class CastReceiverTrustException implements Exception {
  const CastReceiverTrustException(this.message, {required this.kind});

  final String message;
  final CastTrustFailureKind kind;

  @override
  String toString() => message;
}

/// A receiver whose identity has been cryptographically verified, on a
/// particular connection.
///
/// Holding one of these is the *only* evidence the cast layers accept that the
/// thing on the other end of a session is the device the user chose. It is
/// deliberately small: an identity is a claim that was checked, not a channel,
/// a credential, or a capability.
///
/// [deviceId] is the [CastDevice.id] the identity was established for, so the
/// binding to the user's selection can be checked rather than assumed.
/// [connection] is the session the proof was made over, so the binding to the
/// socket that will carry the media can be checked too: a receiver proving
/// itself on one connection says nothing about another, and Cast's own device
/// authentication is a property of a connection, not of a name on the network.
/// [fingerprint] is a stable, non-secret digest of the verified receiver
/// certificate — enough to notice that a device answering to the same name is
/// not the same hardware, and useless to anyone who learns it.
@immutable
class CastReceiverIdentity {
  const CastReceiverIdentity({
    required this.deviceId,
    required this.connection,
    required this.fingerprint,
    this.model,
  });

  /// The id of the [CastDevice] this identity belongs to.
  final String deviceId;

  /// The session the proof was made over. The media handoff happens on this
  /// same session, which is what makes the proof worth anything.
  final CastSessionHandle connection;

  /// A stable, non-secret digest of the verified receiver certificate.
  final String fingerprint;

  /// What the receiver says it is (e.g. a model name), when the verified
  /// material carries it. Informational only — never a trust input.
  final String? model;

  /// Whether this identity is what the user's chosen [device] must present, on
  /// the very [session] that will carry the media. Both halves matter: the
  /// right device on another connection is not the receiver we are about to
  /// hand a stream to.
  bool matches(CastDevice device, CastSessionHandle session) =>
      device.id == deviceId && identical(session, connection);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CastReceiverIdentity &&
          other.deviceId == deviceId &&
          identical(other.connection, connection) &&
          other.fingerprint == fingerprint &&
          other.model == model);

  @override
  int get hashCode =>
      Object.hash(deviceId, identityHashCode(connection), fingerprint, model);

  @override
  String toString() =>
      'CastReceiverIdentity(deviceId: $deviceId, fingerprint: $fingerprint)';
}

/// Proves that a receiver is the device the user picked, or refuses.
///
/// This is the contract [#575](https://github.com/TheZupZup/Linthra/issues/575)
/// is about: casting stays withheld until a receiver's identity is
/// cryptographically authenticated and the whole handoff path has been reviewed.
/// Splitting the *contract* from the eventual implementation means the boundary
/// the app enforces — no trusted identity, no session, no media — is written
/// down, tested, and reviewable now, and the implementation choice (a maintained
/// package, an auditable fork, or a narrowly scoped replacement) is reviewed on
/// its own terms in the private advisory. See docs/design/cast-receiver-trust.md.
///
/// Implementations must:
///  * perform the check over the session they are handed, because that is the
///    connection the media will go to. Cast's device authentication is a
///    challenge answered on a connection; a proof gathered anywhere else
///    describes a different conversation;
///  * complete only after the receiver has actually proved its identity, never
///    on "the socket opened" or "the device replied";
///  * return an identity naming both the requested device and that session, so
///    the caller can check the binding rather than trust the implementation to
///    have checked it;
///  * throw [CastReceiverTrustException] for every other outcome, including the
///    ones that look like infrastructure (timeouts, dropped connections). An
///    inconclusive check is a failure;
///  * never return a partially verified identity, and never carry handshake
///    material out of this call.
abstract interface class CastReceiverAuthenticator {
  /// Authenticates the receiver reached over [session] — which the user picked
  /// as [device] — and returns its verified identity, or throws a
  /// [CastReceiverTrustException].
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  );
}

/// The shipped authenticator: it trusts nothing, because nothing here can yet
/// prove a receiver's identity.
///
/// It is not a placeholder that "will do for now" — it is the fail-closed half
/// of the boundary. While casting is contained no transport is built at all, and
/// when one is built again it must arrive with a real authenticator in the same
/// reviewed change; until that lands, every receiver is refused here rather than
/// waved through by a default that says yes.
class UnverifiedCastReceiverAuthenticator implements CastReceiverAuthenticator {
  const UnverifiedCastReceiverAuthenticator();

  /// What the sheet would say. Free of any detail about the report, and honest
  /// about the reason: the app cannot check the device, so it will not use it.
  static const String message =
      "Linthra can't verify this device yet, so it won't send your music to it.";

  @override
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) async {
    throw const CastReceiverTrustException(
      message,
      kind: CastTrustFailureKind.unsupported,
    );
  }
}
