import 'package:flutter/foundation.dart';

/// Remembers which receiver certificate a given cast device presented, so that
/// "a genuine Cast device" can be narrowed to "*your* Cast device".
///
/// Receiver authentication (`CastReceiverAuthenticator`) answers a different
/// question than people assume. Cast's device authentication proves that the
/// thing on the other end holds a manufacturer certificate chaining to a Cast
/// root: it is a real, licensed receiver. It does not prove that it is the
/// receiver the user meant. Discovery is a name and an address on a LAN, both
/// unauthenticated, so a second genuine receiver (a neighbour's, a guest's, one
/// plugged in by someone else on the same network) can answer to a familiar
/// name and pass authentication honestly.
///
/// Pinning closes that gap the only way a client can: the first time a device is
/// used, the fingerprint of the certificate it proved itself with is recorded
/// against it; every later connection has to present the same one. It is
/// trust-on-first-use, with all of that model's limits (see
/// docs/design/cast-hardened.md), and it is still the difference between
/// noticing a swapped receiver and never being able to.
///
/// Fingerprints are not secrets. They are digests of a certificate the device
/// hands to anyone who connects, so a store needs no encryption, only
/// integrity and an answer the app can rely on.
abstract interface class CastReceiverPinStore {
  /// The fingerprint remembered for [deviceId], or null if this device has not
  /// been used before.
  ///
  /// Throwing is allowed and is treated as "unknown, and not safe to guess":
  /// the connection is refused rather than re-pinned. A store that cannot answer
  /// cannot tell a first use apart from a swapped device.
  Future<String?> pinFor(String deviceId);

  /// Records [fingerprint] as the receiver for [deviceId].
  ///
  /// Only ever called for a device with no pin yet, and always with a
  /// fingerprint already put through [normalizeCastFingerprint], so what is
  /// stored is canonical. Implementations must not overwrite an existing pin
  /// here: replacing one is a deliberate act by the user, through [forget], not
  /// a side effect of connecting.
  Future<void> remember(String deviceId, String fingerprint);

  /// Drops what is remembered for [deviceId], so the next connection pins
  /// afresh.
  ///
  /// This is the "I replaced my speaker" path, and it belongs behind an explicit
  /// user action. Nothing in the trust path may call it to recover from a
  /// mismatch: that would turn the check into a formality.
  Future<void> forget(String deviceId);
}

/// A pin store that lasts as long as the app is running.
///
/// This is the default so that the absence of a configured store can never mean
/// the absence of pinning: the worst case is a shorter memory, not a missing
/// check. A restored cast feature is expected to supply a persistent store; see
/// docs/design/cast-hardened.md.
class InMemoryCastReceiverPinStore implements CastReceiverPinStore {
  InMemoryCastReceiverPinStore();

  final Map<String, String> _pins = <String, String>{};

  /// What is currently remembered, so a test can show what was pinned.
  /// Fingerprints are public material, so this leaks nothing.
  @visibleForTesting
  Map<String, String> get pins => Map<String, String>.unmodifiable(_pins);

  @override
  Future<String?> pinFor(String deviceId) async => _pins[deviceId];

  @override
  Future<void> remember(String deviceId, String fingerprint) async {
    // Deliberately not an overwrite: the contract says a pin is only ever
    // recorded for a device that has none, and an implementation that quietly
    // replaced one would hide exactly the event this exists to catch.
    _pins.putIfAbsent(deviceId, () => fingerprint);
  }

  @override
  Future<void> forget(String deviceId) async {
    _pins.remove(deviceId);
  }
}

/// Puts a certificate fingerprint in one shape so that formatting can never
/// decide a security question.
///
/// The same digest is written `AB:CD:EF`, `ab:cd:ef` or `ab cd ef` depending on
/// who printed it, and comparing those literally would make a cosmetic change in
/// an authenticator read as a swapped device. Only case and the two characters
/// used to separate a printed fingerprint, the colon and whitespace, are
/// removed.
///
/// Deliberately not `-` or `_`, tempting as they look: those are digits of a
/// base64url digest, and dropping them could make two different fingerprints
/// compare equal. Everything left out of this list fails the comparison, which
/// is a refusal the user can see, and refusing a fingerprint written in an
/// unexpected shape is the safe direction to be wrong in.
String normalizeCastFingerprint(String fingerprint) {
  return fingerprint.toLowerCase().replaceAll(RegExp(r'[\s:]'), '');
}
