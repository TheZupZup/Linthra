import '../../models/track.dart';

/// A **credential-free** identity for a remote track in the remote playback
/// cache.
///
/// This is the one place that decides *what may be keyed* — and it is the
/// security boundary for the whole cache foundation. A cache key (and anything
/// derived from it: an on-disk filename, a metadata row, a diagnostics line)
/// must NEVER carry a token, salt, password, or an authenticated stream URL. So
/// a key is built only from a track's stable, opaque [Track.uri] —
/// `jellyfin:<id>`, `subsonic:<id>`, `plex:<ratingKey>` — none of which embed a
/// credential (the token is woven into the *stream URL* at play time, never
/// onto the track). Local files (`/music/a.mp3`, `file://…`) and Android
/// `content://` documents have no remote credential to protect and gain nothing
/// from remote caching, so they are deliberately **not** keyable here: a
/// non-remote track yields `null`.
///
/// As defence in depth, [forUri] refuses to key anything that *looks* tokenized
/// (a query string, or a known secret marker) even though a well-formed remote
/// `uri` never contains one — a malformed or future input can't smuggle a
/// secret into a filename through this seam.
class RemoteCacheKey {
  const RemoteCacheKey._(this.sourceId, this.value);

  /// The provider that owns the track (`jellyfin` / `subsonic` / `plex`), taken
  /// from the URI scheme. Safe to log and to use as a metadata column.
  final String sourceId;

  /// The credential-free stable identity — the track's own opaque `uri`. Safe
  /// to log, persist, and (via [fileSafeName]) turn into a filename.
  final String value;

  /// Remote stream schemes worth caching/prebuffering. Local files and
  /// `content://` documents open instantly and carry no credential, so they are
  /// excluded by omission. Kept here (rather than imported from the source
  /// layer) so this services-layer seam stays free of a dependency on the
  /// provider implementations, mirroring `StreamPreloadingResolver`.
  static const String sourceIdJellyfin = 'jellyfin';
  static const String sourceIdSubsonic = 'subsonic';
  static const String sourceIdPlex = 'plex';

  static const Set<String> remoteSchemes = <String>{
    sourceIdJellyfin,
    sourceIdSubsonic,
    sourceIdPlex,
  };

  /// Substrings that must never appear in a key. A credential-free remote id is
  /// `scheme:<opaque-id>` with no query and no secret; if any of these is
  /// present the input is treated as unsafe and refused (yields `null`), so a
  /// token can never reach a cache filename or metadata via this seam.
  static const List<String> _forbiddenMarkers = <String>[
    '?',
    'token',
    'api_key',
    'apikey',
    'x-plex-token',
    'x-emby-token',
    'access_token',
    'password',
    'authorization',
    'salt=',
    '&t=',
  ];

  /// The key for [track], or `null` when the track is not a cacheable remote
  /// stream (a local file, a `content://` document, or anything tokenized).
  static RemoteCacheKey? forTrack(Track track) => forUri(track.uri);

  /// The key for a raw [uri], or `null` when it is not a safe remote id.
  static RemoteCacheKey? forUri(String uri) {
    final String? scheme = _schemeOf(uri);
    if (scheme == null || !remoteSchemes.contains(scheme)) return null;
    final String lower = uri.toLowerCase();
    for (final String marker in _forbiddenMarkers) {
      if (lower.contains(marker)) return null;
    }
    return RemoteCacheKey._(scheme, uri);
  }

  /// Whether [track] is a cacheable remote stream (the inverse of "local /
  /// `content://` / tokenized"). A convenience for policy code that doesn't need
  /// the key itself.
  static bool isRemote(Track track) => forTrack(track) != null;

  static String? _schemeOf(String uri) {
    final int colon = uri.indexOf(':');
    if (colon <= 0) return null;
    return uri.substring(0, colon).toLowerCase();
  }

  /// A filesystem-safe, bounded name derived from this (already credential-free)
  /// key, for the **future** on-disk prebuffer/cache. The value carries no
  /// secret, so this only makes it path-safe and length-bounded; a stable
  /// non-secret hash of the value disambiguates ids that sanitize to the same
  /// string. Never contains a token because [value] never does.
  String get fileSafeName {
    final String sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final String head =
        sanitized.length <= 64 ? sanitized : sanitized.substring(0, 64);
    final String digest = value.hashCode.toUnsigned(32).toRadixString(16);
    return '${sourceId}_${head}_$digest';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RemoteCacheKey && other.value == value);

  @override
  int get hashCode => value.hashCode;

  /// The credential-free [value]; safe to log.
  @override
  String toString() => value;
}
