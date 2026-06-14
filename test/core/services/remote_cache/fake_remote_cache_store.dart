import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_store.dart';

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
