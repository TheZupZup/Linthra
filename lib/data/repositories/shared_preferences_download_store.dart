import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/download_store.dart';

/// A [DownloadStore] backed by `shared_preferences`.
///
/// The durable part of the offline cache is a small set of track→file
/// references, so a key/value store is the right weight here — the same
/// reasoning the selected music folder follows. The references are kept as a
/// single JSON document (track id + cache file name); when downloads also need
/// byte progress, this is the seam that graduates to a Drift/SQLite table
/// without the policy in `CacheDownloadRepository` changing.
///
/// Security: only the non-secret track id and a track-id-derived file name are
/// persisted — never a token or an authenticated URL.
class SharedPreferencesDownloadStore implements DownloadStore {
  const SharedPreferencesDownloadStore();

  // A JSON document under a v2 key. The pre-1.0 IDs-only key is intentionally
  // not migrated (there were no remote downloads to preserve).
  static const String _key = 'offline_downloads_v2';

  @override
  Future<List<CachedTrack>> loadDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const <CachedTrack>[];

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // A corrupt record reads as "nothing downloaded" rather than crashing.
      return const <CachedTrack>[];
    }
    if (decoded is! List) return const <CachedTrack>[];

    final List<CachedTrack> downloads = <CachedTrack>[];
    for (final Object? entry in decoded) {
      if (entry is Map<String, dynamic>) {
        final CachedTrack? cached = CachedTrack.fromJson(entry);
        if (cached != null) downloads.add(cached);
      }
    }
    return downloads;
  }

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    final prefs = await SharedPreferences.getInstance();
    final String raw = jsonEncode(
      <Map<String, dynamic>>[for (final c in downloads) c.toJson()],
    );
    await prefs.setString(_key, raw);
  }
}
