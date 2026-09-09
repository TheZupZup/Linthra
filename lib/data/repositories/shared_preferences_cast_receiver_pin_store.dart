import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/cast/cast_receiver_pinning.dart';

/// A [CastReceiverPinStore] that remembers which receiver a cast device is
/// across restarts, backed by `shared_preferences`.
///
/// [InMemoryCastReceiverPinStore] forgets every pin when the app closes, which
/// makes each launch a first use: a swapped receiver is only caught within a
/// single session. Persisting the fingerprint is what turns pinning into the
/// check docs/cast-hardened-design.md describes, and it is the store a restored
/// cast feature is expected to be given
/// ([#575](https://github.com/TheZupZup/Linthra/issues/575)).
///
/// Fingerprints are digests of a certificate the receiver hands to anyone who
/// connects, so there is nothing here to keep secret and no reason to reach for
/// `flutter_secure_storage`. What this store owes is the other two properties:
/// it must answer honestly, and it must not lose a write.
///
/// So, unlike most of Linthra's `shared_preferences` stores, **this one throws
/// rather than degrading**. The others treat unreadable storage as "no
/// preference" because the cost is a default tab or a default theme. Here the
/// cost is the check itself: "I can't read the pin" resolving to "this device
/// has no pin" would re-pin whichever receiver answered, and breaking the store
/// would become the way to erase the check. [TrustGatedCastTransport] turns
/// every throw here into a refusal, which is the direction to be wrong in.
class SharedPreferencesCastReceiverPinStore implements CastReceiverPinStore {
  const SharedPreferencesCastReceiverPinStore();

  /// One key per device rather than one map for all of them: a device id that
  /// cannot be parsed then costs that device its pin, not everybody else's, and
  /// [forget] is a targeted removal instead of a rewrite of every other entry.
  static const String keyPrefix = 'cast_receiver_pin_v1_';

  /// The preference key holding [deviceId]'s pin.
  ///
  /// The id is hashed for shape, not for secrecy (a device id is a name on the
  /// LAN). Discovery hands back whatever the receiver advertises, of whatever
  /// length and with whatever characters in it, and a fixed-width hex digest
  /// keeps that from deciding what a preference key looks like, including the
  /// case where one id, concatenated onto the prefix, spells another id's key.
  static String keyFor(String deviceId) =>
      '$keyPrefix${sha256.convert(utf8.encode(deviceId))}';

  @override
  Future<String?> pinFor(String deviceId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(keyFor(deviceId));
    if (stored == null) return null;

    // A key that exists but holds nothing usable is not a device that has never
    // been cast to. Something wrote it, or something damaged it, and either way
    // this store no longer knows what receiver was pinned. Returning null would
    // re-pin the next one to answer; an empty string would compare equal to
    // nothing and refuse forever with no explanation. Throwing says the true
    // thing: the store cannot answer.
    if (normalizeCastFingerprint(stored).isEmpty) {
      throw StateError('cast receiver pin for a device is unreadable');
    }
    return stored;
  }

  @override
  Future<void> remember(String deviceId, String fingerprint) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String key = keyFor(deviceId);

    // The contract says a pin is only ever recorded for a device that has none.
    // Honouring that here, rather than assuming the caller checked, means a
    // second connection racing the first cannot quietly replace what the first
    // one pinned. The caller reads back afterwards and finds out it lost.
    final String? existing = prefs.getString(key);
    if (existing != null && normalizeCastFingerprint(existing).isNotEmpty) {
      return;
    }

    if (!await prefs.setString(key, fingerprint)) {
      // A write that reported failure has to be a failure to the caller too.
      // Returning normally would hand out a session on a pin that was never
      // recorded, leaving the device unpinned for the next receiver to claim.
      throw StateError('could not record the cast receiver pin for a device');
    }
  }

  @override
  Future<void> forget(String deviceId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(keyFor(deviceId))) {
      // Same reasoning in the other direction: a user who is told the device
      // was forgotten will reconnect and hit the same refusal. Better to fail
      // where the UI can say so.
      throw StateError('could not forget the cast receiver pin for a device');
    }
  }
}
