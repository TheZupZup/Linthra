import '../../core/repositories/subsonic_sync_pending_store.dart';

/// A non-persistent [SubsonicSyncPendingStore] for development and tests.
///
/// The default binding (mirroring the other stores); the running app swaps in
/// the `shared_preferences` binding so an interrupted sync survives a restart.
class InMemorySubsonicSyncPendingStore implements SubsonicSyncPendingStore {
  InMemorySubsonicSyncPendingStore([this._fingerprint]);

  String? _fingerprint;

  @override
  Future<String?> read() async => _fingerprint;

  @override
  Future<void> write(String fingerprint) async {
    _fingerprint = fingerprint;
  }

  @override
  Future<void> clear() async {
    _fingerprint = null;
  }
}
