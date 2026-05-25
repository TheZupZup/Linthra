import '../../models/cast_media.dart';
import '../../models/track.dart';
import 'cast_media_resolver.dart';

/// A [CastMediaResolver] that delegates to the first member able to cast a
/// track, so multiple remote sources (Jellyfin, Subsonic/Navidrome) can be cast
/// through one resolver.
///
/// Mirrors `RoutingPlayableUriResolver`: each source contributes its own
/// resolver, composed here. [canCast] is true when any member can cast the
/// track; [resolve] uses the first member that can. A track no member can cast
/// (an on-device file) yields `canCast == false`, so the caller shows a clear
/// limitation rather than attempting it.
class RoutingCastMediaResolver implements CastMediaResolver {
  const RoutingCastMediaResolver(this._resolvers);

  final List<CastMediaResolver> _resolvers;

  @override
  bool canCast(Track track) =>
      _resolvers.any((CastMediaResolver r) => r.canCast(track));

  @override
  Future<CastMedia> resolve(Track track) async {
    for (final CastMediaResolver resolver in _resolvers) {
      if (resolver.canCast(track)) {
        return resolver.resolve(track);
      }
    }
    // `async` so this surfaces as a rejected future, not a synchronous throw,
    // for callers that `await`.
    throw const CastMediaException(
      "Couldn't cast this track.",
      kind: CastMediaErrorKind.unavailable,
    );
  }
}
