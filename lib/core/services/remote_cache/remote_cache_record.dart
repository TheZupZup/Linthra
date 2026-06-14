import 'remote_cache_entry.dart';
import 'remote_cache_key.dart';

/// The **persistable, credential-free** projection of a remote cache entry.
///
/// Where a [RemoteCacheEntry] is the live, in-memory resolution — and so holds
/// the token-bearing `streamUri` — a [RemoteCacheRecord] is what may safely
/// outlive the process on disk: the entry's credential-free identity plus the
/// timestamps the cleanup sweep needs. It is, deliberately, the entry with the
/// secret cut away.
///
/// Security boundary (the whole reason this type exists): a record is built
/// only from a [RemoteCacheKey] — the track's opaque, credential-free `uri`
/// (`jellyfin:<id>`, `subsonic:<id>`, `plex:<ratingKey>`) — and two timestamps.
/// There is no field that could carry a stream URL, an artwork URL, or a token,
/// so the on-disk manifest physically cannot hold one. [fromEntry] takes the
/// entry's [RemoteCacheEntry.key] and never reads its `streamUri`; [fromJson]
/// re-validates the key through [RemoteCacheKey.forUri] and drops anything that
/// is local, `content://`, or even *looks* tokenized, so a hand-edited or
/// corrupt manifest can't smuggle a secret back in through this seam either.
class RemoteCacheRecord {
  const RemoteCacheRecord({
    required this.key,
    required this.recordedAt,
    required this.expiresAt,
  });

  /// Builds a record from a live [entry], copying **only** its credential-free
  /// [RemoteCacheEntry.key]. The token-bearing `streamUri` is never read, so it
  /// can never reach the persisted form.
  factory RemoteCacheRecord.fromEntry(
    RemoteCacheEntry entry, {
    required DateTime recordedAt,
    required DateTime expiresAt,
  }) =>
      RemoteCacheRecord(
        key: entry.key,
        recordedAt: recordedAt,
        expiresAt: expiresAt,
      );

  /// The credential-free identity of the recorded track. Safe to persist, log,
  /// and (via [RemoteCacheKey.fileSafeName]) turn into a filename.
  final RemoteCacheKey key;

  /// When this track was first prepared into the cache. Kept as non-secret
  /// metadata the future on-disk cache can order/evict by.
  final DateTime recordedAt;

  /// When the record goes stale and the cleanup sweep should drop it. Bounds how
  /// long a credential-free record (and, later, its on-disk bytes) is retained.
  final DateTime expiresAt;

  /// The credential-free key value (the track's opaque `uri`).
  String get value => key.value;

  /// The owning provider (`jellyfin` / `subsonic` / `plex`).
  String get sourceId => key.sourceId;

  /// The filesystem-safe, secret-free name the future on-disk cache keys bytes
  /// by — derived from the (already credential-free) [key].
  String get fileSafeName => key.fileSafeName;

  /// Whether the record is still within its retention window at [now].
  bool isFresh(DateTime now) => now.isBefore(expiresAt);

  /// The credential-free serialized form. Carries the opaque key and the two
  /// timestamps only — never a URL or a token (there is no such field to emit).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key.value,
        'recordedAt': recordedAt.millisecondsSinceEpoch,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
      };

  /// Rebuilds a record from [toJson] output, or returns `null` when the entry is
  /// unusable — a missing key, or a key that is not a safe credential-free
  /// remote id (local, `content://`, or tokenized). Re-validating through
  /// [RemoteCacheKey.forUri] is the load-side half of the security boundary: a
  /// tampered manifest line can never reintroduce a tokenized key, so one bad
  /// record is simply skipped rather than trusted.
  static RemoteCacheRecord? fromJson(Map<String, dynamic> json) {
    final String? rawKey = json['key'] as String?;
    if (rawKey == null || rawKey.isEmpty) return null;
    final RemoteCacheKey? key = RemoteCacheKey.forUri(rawKey);
    if (key == null) return null;
    return RemoteCacheRecord(
      key: key,
      recordedAt: _asDate(json['recordedAt']),
      expiresAt: _asDate(json['expiresAt']),
    );
  }

  /// A millisecond-epoch int back to a [DateTime]; the epoch (treated as long
  /// expired) for a missing or malformed value, so a record with no usable
  /// timestamp is swept rather than kept forever.
  static DateTime _asDate(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RemoteCacheRecord &&
          other.key == key &&
          other.recordedAt == recordedAt &&
          other.expiresAt == expiresAt);

  @override
  int get hashCode => Object.hash(key, recordedAt, expiresAt);

  /// Credential-free by construction (the key never carries a secret); safe to
  /// log and put in diagnostics.
  @override
  String toString() =>
      'remote-cache-record[$key exp=${expiresAt.toIso8601String()}]';
}
