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
  SharedPreferencesDownloadStore();

  // A JSON document under a v2 key. The pre-1.0 IDs-only key is intentionally
  // not migrated (there were no remote downloads to preserve).
  static const String _key = 'offline_downloads_v2';

  // The decoded set memoized against the exact persisted JSON string. The
  // playback read-path (`CachedTrackLocator`) calls [loadDownloads] on *every*
  // resolve — each play, skip, pre-cache and stream-preload — and re-running
  // `jsonDecode` + rebuilding every `CachedTrack` on the UI isolate each time
  // adds up to real jank during rapid skips and pre-cache passes. Keying the
  // cache on the raw string makes a repeat read a cheap string compare + a
  // shallow list copy, and a write (which changes the string) is picked up
  // automatically, so a stale set can never be returned.
  String? _cachedRaw;
  List<CachedTrack> _cachedDownloads = const <CachedTrack>[];

  @override
  Future<List<CachedTrack>> loadDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      _cachedRaw = raw;
      _cachedDownloads = const <CachedTrack>[];
      return <CachedTrack>[];
    }
    if (raw != _cachedRaw) {
      _cachedRaw = raw;
      _cachedDownloads = _decode(raw);
    }
    // Hand back a fresh, caller-owned copy so a caller mutating the list can
    // never corrupt the shared cache (the heavy decode is what was skipped).
    return List<CachedTrack>.of(_cachedDownloads);
  }

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    final prefs = await SharedPreferences.getInstance();
    final String raw = jsonEncode(
      <Map<String, dynamic>>[for (final c in downloads) c.toJson()],
    );
    await prefs.setString(_key, raw);
    // Keep the memo consistent with what was just persisted, so the very next
    // read (common right after a download completes) skips the decode too.
    _cachedRaw = raw;
    _cachedDownloads = List<CachedTrack>.of(downloads);
  }

  /// Decodes the persisted JSON document into records. A corrupt document reads
  /// as "nothing downloaded" rather than crashing.
  static List<CachedTrack> _decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
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
}
