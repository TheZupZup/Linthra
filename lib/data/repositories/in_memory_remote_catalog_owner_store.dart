import '../../core/repositories/remote_catalog_owner_store.dart';

/// A non-persistent [RemoteCatalogOwnerStore] for development and tests.
///
/// This is the default binding (mirroring the other repositories); the running
/// app swaps in the `shared_preferences` binding so the owner survives a
/// restart.
class InMemoryRemoteCatalogOwnerStore implements RemoteCatalogOwnerStore {
  InMemoryRemoteCatalogOwnerStore([Map<String, String>? owners])
      : _owners = <String, String>{...?owners};

  final Map<String, String> _owners;

  @override
  Future<String?> read(String sourceId) async => _owners[sourceId];

  @override
  Future<void> write(String sourceId, String fingerprint) async {
    _owners[sourceId] = fingerprint;
  }

  @override
  Future<void> clear(String sourceId) async {
    _owners.remove(sourceId);
  }
}
