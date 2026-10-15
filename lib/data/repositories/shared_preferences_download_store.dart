import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/download_store.dart';
import 'shared_preferences_write.dart';

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
///
/// A document that can't be read in full (a write cut short, a record from
/// another version) still hands out every record it can, and the first save
/// over it copies it, exactly as it is, to a key of its own that nothing ever
/// deletes. Once that copy exists [holdsUnreadableRecords] stays true, so the
/// files it may name are never taken for abandoned ones.
class SharedPreferencesDownloadStore
    implements DownloadStore, UnreadableDownloadRecords {
  SharedPreferencesDownloadStore();

  // A JSON document under a v2 key. The pre-1.0 IDs-only key is intentionally
  // not migrated (there were no remote downloads to preserve).
  static const String _key = 'offline_downloads_v2';
  static const String _setAsideKey = 'offline_downloads_v2_unreadable';

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
  bool _cachedReadable = true;

  @override
  Future<List<CachedTrack>> loadDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      _cachedRaw = raw;
      _cachedDownloads = const <CachedTrack>[];
      return <CachedTrack>[];
    }
    _remember(raw);
    // Hand back a fresh, caller-owned copy so a caller mutating the list can
    // never corrupt the shared cache (the heavy decode is what was skipped).
    return List<CachedTrack>.of(_cachedDownloads);
  }

  @override
  Future<void> saveDownloads(List<CachedTrack> downloads) async {
    final prefs = await SharedPreferences.getInstance();
    await _setAsideUnreadable(prefs);
    final String raw = jsonEncode(
      <Map<String, dynamic>>[for (final c in downloads) c.toJson()],
    );
    // `false` is a write that didn't happen (a full disk), while the plugin's
    // in-memory copy already holds [raw]: the next launch would read the old
    // document back (#786).
    if (!await prefs.setString(_key, raw)) {
      throw const DownloadStoreWriteException();
    }
    // Keep the memo consistent with what was just persisted, so the very next
    // read (common right after a download completes) skips the decode too.
    _cachedRaw = raw;
    _cachedDownloads = List<CachedTrack>.of(downloads);
    _cachedReadable = true;
  }

  @override
  Future<bool> holdsUnreadableRecords() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.get(_setAsideKey) != null) return true;
    final String? raw = prefs.getString(_key);
    return raw != null && raw.isNotEmpty && !_remember(raw);
  }

  /// Copies the live document to [_setAsideKey] before a save writes over it,
  /// when it couldn't be read in full. One set aside before stays as it is.
  Future<void> _setAsideUnreadable(SharedPreferences prefs) async {
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty || _remember(raw)) return;
    if (prefs.get(_setAsideKey) != null) return;
    final bool copied = await writeOrRestore(
      prefs,
      _setAsideKey,
      () => prefs.setString(_setAsideKey, raw),
    );
    if (!copied) throw const DownloadStoreWriteException();
  }

  /// Decodes [raw] into the memo unless it is what the memo already holds,
  /// and returns whether every part of it could be read.
  bool _remember(String raw) {
    if (raw != _cachedRaw) {
      // Remembered only once decoded: a decode that threw and was remembered
      // anyway would answer "nothing downloaded" for the rest of the session,
      // and the next save would write that over every record.
      final (List<CachedTrack> downloads, bool readable) = _decode(raw);
      _cachedDownloads = downloads;
      _cachedReadable = readable;
      _cachedRaw = raw;
    }
    return _cachedReadable;
  }

  /// Decodes the persisted JSON document into the records it can, and whether
  /// that was all of it. A corrupt document reads as "nothing downloaded"
  /// rather than crashing.
  static (List<CachedTrack>, bool) _decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return (const <CachedTrack>[], false);
    }
    if (decoded is! List) return (const <CachedTrack>[], false);

    final List<CachedTrack> downloads = <CachedTrack>[];
    bool readable = true;
    for (final Object? entry in decoded) {
      final CachedTrack? cached =
          entry is Map<String, dynamic> ? CachedTrack.fromJson(entry) : null;
      if (cached == null) {
        readable = false;
      } else {
        downloads.add(cached);
      }
    }
    return (downloads, readable);
  }
}
