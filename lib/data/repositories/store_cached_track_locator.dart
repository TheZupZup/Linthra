import '../../core/models/track.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/cached_track_locator.dart';

/// The app's [CachedTrackLocator]: answers "is this track available offline?" by
/// reading the durable download metadata ([DownloadStore]) and confirming the
/// bytes are still on disk ([OfflineFileStore]).
///
/// Reading the stores directly — rather than the download repository's
/// in-memory state — keeps the playback read-path decoupled from download
/// *policy*: it sees exactly what has been persisted. A track with no cache
/// file (including any already-local on-device track) resolves to `null`, so
/// playback falls back to its normal source.
class StoreCachedTrackLocator implements CachedTrackLocator {
  const StoreCachedTrackLocator(
    this._store,
    this._files, {
    Future<List<Track>> Function()? catalogForLegacyMatch,
  }) : _catalogForLegacyMatch = catalogForLegacyMatch;

  final DownloadStore _store;
  final OfflineFileStore _files;

  /// Resolves the current catalog so a legacy (untagged, pre-v0.1.6) cache record
  /// is matched by bare id only when that id maps to a single provider — never
  /// serving one provider's bytes for another provider's same-id track. Null
  /// keeps the plain id-only back-compat (tests/dev without provider collisions);
  /// the app wires it to the music library.
  final Future<List<Track>> Function()? _catalogForLegacyMatch;

  @override
  Future<String?> cachedFilePath(Track track) async {
    final String? scheme = _schemeOf(track.uri);
    // Prefer an exact, provider-tagged match (a Plex `101` never resolves to a
    // Subsonic `101`'s file). Fall back to a legacy untagged record (written
    // before source tagging) only if no tagged entry matches.
    String? exact;
    String? untagged;
    for (final CachedTrack cached in await _store.loadDownloads()) {
      if (cached.trackId != track.id) continue;
      if (cached.sourceType == null) {
        untagged ??= cached.fileName;
      } else if (cached.sourceType == scheme) {
        exact = cached.fileName;
        break;
      }
    }
    if (exact != null && exact.isNotEmpty) return _files.pathFor(exact);
    if (untagged == null || untagged.isEmpty) return null;
    // A legacy untagged file carries no provider, so it could belong to a
    // different provider that shares this bare id; only serve it when the catalog
    // shows the id is unambiguous (or no oracle is wired — back-compat).
    if (await _isAmbiguousId(track.id)) return null;
    return _files.pathFor(untagged);
  }

  /// Whether more than one provider in the catalog exposes [bareId], in which
  /// case a legacy untagged cache file can't be safely attributed to [bareId]'s
  /// requested copy. False when no catalog oracle is wired, or on any error, so
  /// playback never blocks on this check.
  Future<bool> _isAmbiguousId(String bareId) async {
    final Future<List<Track>> Function()? oracle = _catalogForLegacyMatch;
    if (oracle == null) return false;
    try {
      final Set<String> providers = <String>{};
      for (final Track track in await oracle()) {
        if (track.id != bareId) continue;
        providers.add(_schemeOf(track.uri) ?? '');
        if (providers.length > 1) return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// The non-secret URI scheme of [uri] (`jellyfin`, `subsonic`, `plex`, `file`,
  /// …), or `null` for a bare path — derived exactly as the repository records
  /// [CachedTrack.sourceType], so the two always agree.
  static String? _schemeOf(String uri) {
    final int colon = uri.indexOf(':');
    if (colon <= 0) return null;
    final String scheme = uri.substring(0, colon).toLowerCase();
    return scheme.isEmpty ? null : scheme;
  }
}
