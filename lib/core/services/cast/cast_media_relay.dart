import '../../models/cast_media.dart';

/// Why a [CastMediaRelay] could not do its job. The [message] is shown to the
/// user as-is, so it is generic by contract: never a token, an address, a port,
/// or an upstream URL.
class CastMediaRelayException implements Exception {
  const CastMediaRelayException(this.message);

  /// The message the cast sheet shows when the relay cannot start. Says what
  /// happened and that nothing was sent, without any network detail.
  static const String unavailableMessage =
      "Couldn't start casting on this network, so casting is off for this "
      'session. Nothing was sent to the cast device.';

  final String message;

  @override
  String toString() => message;
}

/// Re-serves resolved media to a receiver from this device, so the receiver is
/// handed an address on the phone instead of the server's credential-bearing
/// URL.
///
/// A resolver mints a [CastMedia] whose URL carries the account credential
/// (Jellyfin's `ApiKey`, Subsonic's salted token), because that is the only
/// authentication those stream endpoints accept. A relay keeps that URL on the
/// phone: [publish] registers it behind an unguessable, per-item address that
/// only works while the relay is running, and returns media pointing there. The
/// relay then fetches the real stream itself when the receiver asks.
///
/// Lifecycle is owned by the cast service: [start] at the beginning of a cast
/// session, [stop] when it ends. A relay that cannot start is a refusal, never a
/// reason to hand the receiver the original URL instead.
abstract interface class CastMediaRelay {
  /// Whether the relay is currently accepting requests. It can stop on its own
  /// after a long idle period, so callers check this before publishing.
  bool get isRunning;

  /// Starts listening. Throws [CastMediaRelayException] when it cannot (no
  /// usable local network, the port could not be opened). Calling it while
  /// already running is a no-op.
  Future<void> start();

  /// Registers [media] and returns a copy whose URL points at this relay, with
  /// a fresh token for this item. Earlier items stay reachable until [retain]
  /// is called, because the receiver keeps playing the previous item until it
  /// accepts the new one. Throws [CastMediaRelayException] when the relay is
  /// not running.
  CastMedia publish(CastMedia media);

  /// Makes [relayed] (a value [publish] returned) the only reachable item:
  /// every other token is dropped. Called once the receiver accepted it.
  void retain(CastMedia relayed);

  /// Drops [relayed]'s token only. Called when handing it to the receiver
  /// failed, so the item still playing keeps working.
  void revoke(CastMedia relayed);

  /// Marks the session as still active, so the idle shutdown does not fire
  /// while the receiver is plainly still in use.
  void touch();

  /// Stops listening, drops every token, and cuts any transfer still in
  /// flight. Safe to call when not running.
  Future<void> stop();
}
