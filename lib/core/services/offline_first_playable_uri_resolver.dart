import '../models/playback_source.dart';
import '../models/track.dart';
import 'cached_track_locator.dart';
import 'playable_uri_resolver.dart';
import 'playback_diagnostics.dart';

/// A [PlayableUriResolver] that prefers a track's offline-cached file and falls
/// back to another resolver (streaming) when there isn't one.
///
/// This is the single place the "play the local copy if we have it, otherwise
/// stream" rule lives. It wraps the source-routing resolver: a cache hit yields
/// a `file://` URI for the downloaded bytes; a miss delegates to [_fallback],
/// which streams from Jellyfin when online — or surfaces a friendly offline
/// error when not. Local tracks have no managed cache file, so they fall
/// straight through to the on-device resolver and play from their original
/// path.
class OfflineFirstPlayableUriResolver implements PlayableUriResolver {
  const OfflineFirstPlayableUriResolver({
    required CachedTrackLocator locator,
    required PlayableUriResolver fallback,
  })  : _locator = locator,
        _fallback = fallback;

  final CachedTrackLocator _locator;
  final PlayableUriResolver _fallback;

  @override
  bool handles(Track track) => _fallback.handles(track);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final String? cachedPath = await _locator.cachedFilePath(track);
    if (cachedPath != null) {
      PlaybackDiagnostics.resolved(
        source: 'offlineCache',
        resolver: 'OfflineFirstPlayableUriResolver',
        itemId: track.id,
      );
      return ResolvedPlayable(
        Uri.file(cachedPath),
        PlaybackSource.offlineCache,
      );
    }
    // A cache miss falls straight through to streaming (or the on-device
    // resolver) — it is never treated as "offline/unavailable" on its own.
    return _fallback.resolve(track);
  }
}
