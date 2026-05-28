import '../../core/repositories/jellyfin_auto_sync_store.dart';

/// A non-persistent [JellyfinAutoSyncStore] for development and tests.
///
/// Holds the fingerprint in a single field, so it's forgotten when the instance
/// is dropped. This is the default binding (mirroring the other repositories);
/// the running app swaps in the `shared_preferences` binding so the
/// "already auto-synced this account" memory survives restarts.
class InMemoryJellyfinAutoSyncStore implements JellyfinAutoSyncStore {
  InMemoryJellyfinAutoSyncStore([this._fingerprint]);

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
