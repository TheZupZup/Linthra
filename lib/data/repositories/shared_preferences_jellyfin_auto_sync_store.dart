import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/jellyfin_auto_sync_store.dart';

/// A [JellyfinAutoSyncStore] backed by `shared_preferences`.
///
/// Persists a single opaque account fingerprint under one key, so a fresh
/// connection to a new server/account auto-syncs once and a reconnect of an
/// already-synced account does not re-pull the whole library on its own.
///
/// Privacy: the stored value is the non-secret, one-way fingerprint only —
/// never a token, server URL, user id, or authenticated URL — and it stays on
/// the device. Plain `shared_preferences` (not encrypted storage) is fine
/// precisely because there is no secret here.
class SharedPreferencesJellyfinAutoSyncStore implements JellyfinAutoSyncStore {
  const SharedPreferencesJellyfinAutoSyncStore();

  static const String _key = 'jellyfin_auto_sync_account_v1';

  @override
  Future<String?> read() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> write(String fingerprint) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, fingerprint);
  }

  @override
  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
