import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/subsonic_sync_pending_store.dart';

/// A [SubsonicSyncPendingStore] backed by `shared_preferences`, so an
/// interrupted sync is still known about after Android kills the process.
///
/// Privacy: the stored value is the non-secret, one-way account fingerprint
/// only, and it stays on the device. Plain `shared_preferences` (not encrypted
/// storage) is fine precisely because there is no secret here.
class SharedPreferencesSubsonicSyncPendingStore
    implements SubsonicSyncPendingStore {
  const SharedPreferencesSubsonicSyncPendingStore();

  static const String _key = 'subsonic_sync_pending_account_v1';

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
