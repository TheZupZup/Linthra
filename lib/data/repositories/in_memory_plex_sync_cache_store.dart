import '../../core/repositories/plex_sync_cache_store.dart';

/// A non-persistent [PlexSyncCacheStore] for development and tests.
///
/// Holds the last server + signature in memory, so they're forgotten when the
/// instance is dropped. This is the default binding (mirroring the other
/// repositories); the running app swaps in
/// [SharedPreferencesPlexSyncCacheStore] so the "nothing changed" fast path
/// survives restarts.
class InMemoryPlexSyncCacheStore implements PlexSyncCacheStore {
  InMemoryPlexSyncCacheStore({String? machineIdentifier, String? signature})
      : _machineIdentifier = machineIdentifier,
        _signature = signature;

  String? _machineIdentifier;
  String? _signature;

  @override
  Future<String?> readSignature(String machineIdentifier) async =>
      _machineIdentifier == machineIdentifier ? _signature : null;

  @override
  Future<void> writeSignature(
    String machineIdentifier,
    String signature,
  ) async {
    _machineIdentifier = machineIdentifier;
    _signature = signature;
  }

  @override
  Future<void> clear() async {
    _machineIdentifier = null;
    _signature = null;
  }
}
