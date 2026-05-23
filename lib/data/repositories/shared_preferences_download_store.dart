import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/download_store.dart';

/// A [DownloadStore] backed by `shared_preferences`.
///
/// The durable part of the offline cache is just a list of track IDs, so a
/// key/value store is the right weight here — the same reasoning the selected
/// music folder follows. When real remote downloads need per-track file paths
/// and byte progress, this is the seam that graduates to a Drift/SQLite table
/// without the policy in [CacheDownloadRepository] changing.
class SharedPreferencesDownloadStore implements DownloadStore {
  const SharedPreferencesDownloadStore();

  static const String _key = 'downloaded_track_ids';

  @override
  Future<Set<String>> loadDownloadedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  @override
  Future<void> saveDownloadedIds(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, ids.toList());
  }
}
