import '../models/track.dart';
import 'playable_uri_resolver.dart';

/// A [PlayableUriResolver] that delegates to the first member resolver able to
/// [PlayableUriResolver.handles] a track.
///
/// This is how the playback controller stays unaware of where a track comes
/// from: local files, Jellyfin items, and (later) other sources each get their
/// own resolver, composed here in priority order. More specific resolvers
/// should come first; a catch-all local resolver last.
class RoutingPlayableUriResolver implements PlayableUriResolver {
  const RoutingPlayableUriResolver(this._resolvers);

  final List<PlayableUriResolver> _resolvers;

  @override
  bool handles(Track track) =>
      _resolvers.any((PlayableUriResolver r) => r.handles(track));

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    for (final PlayableUriResolver resolver in _resolvers) {
      if (resolver.handles(track)) {
        return resolver.resolve(track);
      }
    }
    // `async` so this surfaces as a rejected future (like the member
    // resolvers), not a synchronous throw, for callers that `await`.
    throw const PlaybackResolutionException(
      "This track can't be played right now.",
      kind: PlaybackResolutionErrorKind.streamUnavailable,
    );
  }
}
