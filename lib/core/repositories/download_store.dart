/// A reference to a single offline-cached track: which track it is, the file
/// that holds its downloaded bytes (when there is one), and the small bits of
/// metadata the cache manager needs to clean up intelligently.
///
/// Security invariant: this is *persisted* metadata, so it must never carry a
/// secret. [trackId] is the non-secret catalog id, and [fileName] is derived
/// from it — never from an access token or an authenticated URL. [sourceType]
/// is the track's non-secret URI scheme (e.g. `jellyfin`, `file`), never the
/// full URL. Do not add the streaming/download URL, a Jellyfin token, or any
/// credential to this record.
class CachedTrack {
  const CachedTrack({
    required this.trackId,
    this.fileName,
    this.sourceType,
    this.sizeBytes = 0,
    this.cachedAt,
    this.lastAccessedAt,
    this.pinned = false,
    this.preloaded = false,
  });

  /// The catalog id of the cached track.
  final String trackId;

  /// The cache file holding the downloaded bytes, relative to the offline
  /// directory — or `null` for an on-device track that is already local and so
  /// has no managed copy of its own.
  final String? fileName;

  /// The non-secret URI scheme the track came from (`jellyfin`, `file`, …),
  /// kept so the cache can show/group by source. Never the full URL.
  final String? sourceType;

  /// The size of the managed cache file in bytes, captured at download time.
  /// `0` for an on-device track (no managed bytes), so only app-managed
  /// downloads count toward the cache budget.
  final int sizeBytes;

  /// When the bytes were first cached. `null` for legacy/on-device records.
  final DateTime? cachedAt;

  /// When the track was last played from cache — the signal least-recently-used
  /// eviction sorts on. `null` means never accessed (treated as oldest).
  final DateTime? lastAccessedAt;

  /// Whether the user pinned this track ("Keep offline"). Pinned tracks are
  /// never evicted automatically and survive "clear unpinned".
  final bool pinned;

  /// Whether this entry was *auto-preloaded* (prefetched ahead of play) rather
  /// than explicitly downloaded by the user. Preloaded entries count toward the
  /// cache budget but never appear as user downloads, and are evicted before any
  /// user download when space is needed (see [CacheEvictionPolicy]). Cleared
  /// when the user explicitly downloads the same track, promoting it.
  final bool preloaded;

  /// Whether this record points at app-managed downloaded bytes (vs. an
  /// on-device track that is merely marked available offline).
  bool get isManaged => fileName != null && fileName!.isNotEmpty;

  /// The provider-aware cache identity — the source scheme plus the catalog id —
  /// so two providers that expose the same catalog id (a Plex ratingKey `101`
  /// and a Subsonic id `101`) never share a cache slot, file, or eviction
  /// decision. The shared cache and [CacheEvictionPolicy] key on this, never on
  /// the bare [trackId].
  String get cacheKey => cacheKeyFor(sourceType, trackId);

  /// Builds a [cacheKey] from a raw `(sourceType, trackId)` pair, so a live
  /// track (which has no [CachedTrack] yet) keys exactly the way a persisted
  /// entry keys itself. The NUL separator can't occur in a scheme or an id, so
  /// the pair is unambiguous.
  static String cacheKeyFor(String? sourceType, String trackId) =>
      '${sourceType ?? ''}${String.fromCharCode(_keySeparator)}$trackId';

  /// The catalog id encoded in a [cacheKey] / [cacheKeyFor] value — everything
  /// after the scheme separator (the inverse of the id half of [cacheKeyFor]).
  /// Lets the eviction policy recover the bare id to match a legacy record that
  /// predates [sourceType] and so can't carry the provider-aware key.
  static String trackIdFromKey(String key) {
    final int i = key.indexOf(String.fromCharCode(_keySeparator));
    return i < 0 ? key : key.substring(i + 1);
  }

  /// Separator between scheme and id in a [cacheKey]: NUL, which can't occur in
  /// a URI scheme or a catalog id, so the `(scheme, id)` pair is unambiguous.
  static const int _keySeparator = 0;

  CachedTrack copyWith({
    String? fileName,
    String? sourceType,
    int? sizeBytes,
    DateTime? cachedAt,
    DateTime? lastAccessedAt,
    bool? pinned,
    bool? preloaded,
  }) {
    return CachedTrack(
      trackId: trackId,
      fileName: fileName ?? this.fileName,
      sourceType: sourceType ?? this.sourceType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      cachedAt: cachedAt ?? this.cachedAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      pinned: pinned ?? this.pinned,
      preloaded: preloaded ?? this.preloaded,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'trackId': trackId,
        if (isManaged) 'fileName': fileName,
        if (sourceType != null && sourceType!.isNotEmpty)
          'sourceType': sourceType,
        if (sizeBytes > 0) 'sizeBytes': sizeBytes,
        if (cachedAt != null) 'cachedAt': cachedAt!.millisecondsSinceEpoch,
        if (lastAccessedAt != null)
          'lastAccessedAt': lastAccessedAt!.millisecondsSinceEpoch,
        if (pinned) 'pinned': true,
        if (preloaded) 'preloaded': true,
      };

  /// Rebuilds a record from [toJson] output, or returns `null` when the track
  /// id is missing (a corrupt entry), so one bad record can't break loading.
  /// Records written by an earlier version (id + file name only) load cleanly:
  /// the new fields fall back to their defaults.
  static CachedTrack? fromJson(Map<String, dynamic> json) {
    final String? trackId = json['trackId'] as String?;
    if (trackId == null || trackId.isEmpty) return null;
    final String? fileName = json['fileName'] as String?;
    final String? sourceType = json['sourceType'] as String?;
    return CachedTrack(
      trackId: trackId,
      fileName: (fileName != null && fileName.isNotEmpty) ? fileName : null,
      sourceType:
          (sourceType != null && sourceType.isNotEmpty) ? sourceType : null,
      sizeBytes: _asInt(json['sizeBytes']),
      cachedAt: _asDate(json['cachedAt']),
      lastAccessedAt: _asDate(json['lastAccessedAt']),
      pinned: json['pinned'] == true,
      preloaded: json['preloaded'] == true,
    );
  }

  static int _asInt(Object? value) {
    if (value is int) return value < 0 ? 0 : value;
    return 0;
  }

  static DateTime? _asDate(Object? value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedTrack &&
          other.trackId == trackId &&
          other.fileName == fileName &&
          other.sourceType == sourceType &&
          other.sizeBytes == sizeBytes &&
          other.cachedAt == cachedAt &&
          other.lastAccessedAt == lastAccessedAt &&
          other.pinned == pinned &&
          other.preloaded == preloaded);

  @override
  int get hashCode => Object.hash(
        trackId,
        fileName,
        sourceType,
        sizeBytes,
        cachedAt,
        lastAccessedAt,
        pinned,
        preloaded,
      );
}

/// Durable storage for the tracks that are available offline.
///
/// This is the *persistence seam* under [DownloadRepository]: it knows nothing
/// about download policy, connectivity, or the transient queued/downloading
/// states — only which tracks are cached and the metadata the cache manager
/// cleans up by (file, size, timestamps, pinned). Splitting it out keeps the
/// download lifecycle (policy) in one place while letting the backing store
/// swap freely (in-memory for tests, key/value in the app, a SQLite/Drift
/// table once downloads also track byte progress).
abstract interface class DownloadStore {
  /// The tracks currently cached for offline use.
  Future<List<CachedTrack>> loadDownloads();

  /// Replaces the persisted set with [downloads].
  Future<void> saveDownloads(List<CachedTrack> downloads);
}
