import '../models/track.dart';
import '../repositories/download_store.dart';

/// An immutable view of the offline cache for the UI: how much app-managed
/// space is in use and the per-track metadata behind it.
///
/// [usedBytes] counts only app-managed downloaded bytes — on-device tracks
/// marked available offline hold no managed bytes and don't count. The maximum
/// limit is *not* here: it lives in [DownloadPreferences] (the user can change
/// it independently), and the UI composes the two to show "used of max".
class CacheSnapshot {
  const CacheSnapshot({
    required this.usedBytes,
    required this.entries,
  });

  static const CacheSnapshot empty =
      CacheSnapshot(usedBytes: 0, entries: <CachedTrack>[]);

  /// Total bytes held in app-managed cache files.
  final int usedBytes;

  /// Every offline entry (managed downloads and on-device markers alike).
  final List<CachedTrack> entries;

  /// How many entries hold app-managed bytes (i.e. real downloads).
  int get managedCount => entries.where((CachedTrack e) => e.isManaged).length;
}

/// The cache-maintenance surface the UI drives, kept separate from the
/// download *lifecycle* ([DownloadRepository.requestDownload] / status).
///
/// Everything that frees or pins app-managed files goes through here so the UI
/// never deletes files or computes eviction itself — it just asks the manager,
/// which owns the policy and the filesystem. The same instance backs the
/// download repository, so a cleared/pinned track is reflected in download
/// status too.
abstract interface class OfflineCacheManager {
  /// Emits the current [CacheSnapshot] immediately, then again on every change
  /// (download, removal, eviction, pin, play, or clear).
  Stream<CacheSnapshot> get cacheStream;

  /// The current snapshot, for a one-off read.
  Future<CacheSnapshot> cacheSnapshot();

  /// Pins or unpins a track ("Keep offline"). Pinned tracks are never evicted
  /// automatically and survive [clearUnpinned]. A no-op for an unknown track.
  /// Takes the whole [Track] so it acts on the right provider's cached copy.
  Future<void> setPinned(Track track, bool pinned);

  /// Records that [track] was just played from cache, refreshing its
  /// least-recently-used position. A no-op for a track that isn't cached.
  Future<void> notePlayed(Track track);

  /// Removes every offline entry: deletes all app-managed cache files and the
  /// metadata, pinned items included. Never touches the user's local source
  /// files (those have no app-managed file).
  Future<void> clearAll();

  /// Removes only unpinned offline entries, deleting their app-managed cache
  /// files. Pinned ("Keep offline") tracks are preserved.
  Future<void> clearUnpinned();
}
