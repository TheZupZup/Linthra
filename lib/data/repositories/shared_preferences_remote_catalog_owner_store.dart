import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/remote_catalog_owner_store.dart';

/// A [RemoteCatalogOwnerStore] backed by `shared_preferences`: one key per
/// source id, holding the owning account's fingerprint.
///
/// Privacy: the stored value is the non-secret, one-way fingerprint only, so
/// plain `shared_preferences` (not encrypted storage) is fine.
class SharedPreferencesRemoteCatalogOwnerStore
    implements RemoteCatalogOwnerStore {
  const SharedPreferencesRemoteCatalogOwnerStore();

  static String _key(String sourceId) => 'remote_catalog_owner_v1_$sourceId';

  @override
  Future<String?> read(String sourceId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key(sourceId));
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> write(String sourceId, String fingerprint) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(sourceId), fingerprint);
  }

  @override
  Future<void> clear(String sourceId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(sourceId));
  }
}
