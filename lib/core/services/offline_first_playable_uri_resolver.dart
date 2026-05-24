import '../models/track.dart';
import 'cached_track_locator.dart';
import 'playable_uri_resolver.dart';

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
  Future<Uri> resolve(Track track) async {
    final String? cachedPath = await _locator.cachedFilePath(track);
    if (cachedPath != null) {
      return Uri.file(cachedPath);
    }
    return _fallback.resolve(track);
  }
}
