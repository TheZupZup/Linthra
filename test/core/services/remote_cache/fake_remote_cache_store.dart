import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_store.dart';

/// A credential-free record for [uri] (`jellyfin:` / `subsonic:` / `plex:`), for
/// seeding the fake store in disconnect/sign-out tests. It is built from an entry
/// whose stream URL carries a token — exactly the thing that must not survive
/// into the persisted record.
///
/// Defaults [recordedAt] to `DateTime.now()` (not a fixed date) so the 30-day
/// retention leaves the record *fresh* against a real-clock index — otherwise a
/// controller test's index would prune the seed as stale before the disconnect
/// even runs.
RemoteCacheRecord fakeRemoteCacheRecord(String uri, {DateTime? recordedAt}) {
  final DateTime now = recordedAt ?? DateTime.now();
  return RemoteCacheRecord.fromEntry(
    RemoteCacheEntry(
      key: RemoteCacheKey.forUri(uri)!,
      streamUri: Uri.parse('https://server.example/stream?api_key=SECRET'),
      source: PlaybackSource.streamingDirect,
      resolvedAt: now,
      expiresAt: now.add(const Duration(minutes: 2)),
    ),
    recordedAt: now,
    expiresAt: now.add(const Duration(days: 30)),
  );
}

/// An in-memory [RemoteCacheStore] for the durable-index tests.
///
/// It stands in for the on-disk JSON manifest without touching the filesystem:
/// it remembers the last-saved records, counts loads/saves so a test can prove
/// the index persisted (or didn't), and can be told to throw on either call so
/// the index's "best-effort, never fatal" contract is provable.
class FakeRemoteCacheStore implements RemoteCacheStore {
  FakeRemoteCacheStore({
    List<RemoteCacheRecord> seed = const <RemoteCacheRecord>[],
    this.failOnLoad = false,
    this.failOnSave = false,
  }) : _records = List<RemoteCacheRecord>.of(seed);

  List<RemoteCacheRecord> _records;

  /// When true, [load] throws — to prove the index degrades to a cold cache.
  bool failOnLoad;

  /// When true, [save] throws — to prove a warm/sweep is still non-fatal.
  bool failOnSave;

  int loadCount = 0;
  int saveCount = 0;

  /// The records handed to the most recent [save] (what would hit disk).
  List<RemoteCacheRecord> get saved => List<RemoteCacheRecord>.of(_records);

  @override
  Future<List<RemoteCacheRecord>> load() async {
    loadCount++;
    if (failOnLoad) throw StateError('load failed');
    return List<RemoteCacheRecord>.of(_records);
  }

  @override
  Future<void> save(List<RemoteCacheRecord> records) async {
    saveCount++;
    if (failOnSave) throw StateError('save failed');
    _records = List<RemoteCacheRecord>.of(records);
  }
}
