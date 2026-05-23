import '../../models/track.dart';
import '../../services/playable_uri_resolver.dart';
import 'jellyfin_exception.dart';
import 'jellyfin_stream_source.dart';
import 'jellyfin_track_mapper.dart';

/// Resolves Jellyfin tracks to authenticated streaming URLs at play time.
///
/// The token is woven into the URL here, on demand by the
/// [JellyfinStreamSource], and never stored on the track or in the catalog.
/// Before minting, this verifies the session is still valid and the server
/// reachable, so the player can show a precise, friendly error (expired session
/// vs. unreachable server) instead of an opaque audio-engine failure. The
/// minted URL is returned to the controller and handed to the engine — it is
/// never logged, never placed in [Track], and never put into player state.
///
/// The current signed-in source is read through a getter so signing in or out
/// is reflected without rebuilding the controller; the resolver depends only on
/// the narrow [JellyfinStreamSource], never on Riverpod or HTTP.
class JellyfinPlayableUriResolver implements PlayableUriResolver {
  const JellyfinPlayableUriResolver(this._source);

  /// Supplies the current signed-in source, or `null` when not connected.
  final JellyfinStreamSource? Function() _source;

  @override
  bool handles(Track track) =>
      track.uri.startsWith(JellyfinTrackMapper.uriScheme);

  @override
  Future<Uri> resolve(Track track) async {
    final JellyfinStreamSource? source = _source();
    if (source == null) {
      throw const PlaybackResolutionException(
        "You're not signed in to Jellyfin. Connect to your server in Settings "
        'to play this track.',
        kind: PlaybackResolutionErrorKind.notSignedIn,
      );
    }

    // Confirm the session still works before streaming, turning a 401 / network
    // failure into a precise message rather than a generic playback error.
    try {
      await source.verifyReachable();
    } on JellyfinException catch (error) {
      throw _mapVerifyFailure(error);
    }

    final Uri? uri = await source.resolvePlayableUri(track);
    if (uri == null) {
      throw const PlaybackResolutionException(
        "This Jellyfin track can't be streamed right now. Try syncing your "
        'library again.',
        kind: PlaybackResolutionErrorKind.streamUnavailable,
      );
    }
    return uri;
  }

  /// Maps a verification failure to a friendly, secret-free playback error.
  /// Branches on [JellyfinErrorKind] so wording can change without breaking it.
  PlaybackResolutionException _mapVerifyFailure(JellyfinException error) {
    switch (error.kind) {
      case JellyfinErrorKind.unauthorized:
        return const PlaybackResolutionException(
          'Your Jellyfin session has expired. Sign out and sign in again in '
          'Settings to keep playing.',
          kind: PlaybackResolutionErrorKind.sessionExpired,
        );
      case JellyfinErrorKind.notReachable:
      case JellyfinErrorKind.notJellyfin:
      case JellyfinErrorKind.serverError:
      case JellyfinErrorKind.invalidUrl:
      case JellyfinErrorKind.unexpected:
        return const PlaybackResolutionException(
          "Couldn't reach your Jellyfin server. Check your connection and that "
          'the server is online.',
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
    }
  }
}
