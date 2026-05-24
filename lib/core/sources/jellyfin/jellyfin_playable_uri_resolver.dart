import '../../models/playback_source.dart';
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
  Future<ResolvedPlayable> resolve(Track track) async {
    final JellyfinStreamSource? source = _source();
    if (source == null) {
      throw const PlaybackResolutionException(
        'Sign in to Jellyfin before streaming this track.',
        kind: PlaybackResolutionErrorKind.notSignedIn,
      );
    }

    // Confirm the session still works, then mint and probe the stream URL —
    // both can throw a typed [JellyfinException], which becomes a precise,
    // secret-free message rather than the engine's opaque "couldn't play".
    final Uri? uri;
    try {
      await source.verifyReachable();
      uri = await source.resolvePlayableUri(track);
    } on JellyfinException catch (error) {
      throw _mapFailure(error);
    }

    if (uri == null) {
      throw const PlaybackResolutionException(
        "Couldn't stream this track.",
        kind: PlaybackResolutionErrorKind.streamUnavailable,
      );
    }
    return ResolvedPlayable(uri, PlaybackSource.streamingDirect);
  }

  /// Maps a Jellyfin failure (from the session check or the stream probe) to a
  /// friendly, secret-free playback error. Branches on [JellyfinErrorKind] so
  /// wording can change without breaking it, and so a new kind is a compile
  /// error here rather than a silent generic message.
  PlaybackResolutionException _mapFailure(JellyfinException error) {
    switch (error.kind) {
      case JellyfinErrorKind.unauthorized:
        return const PlaybackResolutionException(
          'Your Jellyfin session expired. Sign in again.',
          kind: PlaybackResolutionErrorKind.sessionExpired,
        );
      case JellyfinErrorKind.webPage:
      case JellyfinErrorKind.notJellyfin:
        return const PlaybackResolutionException(
          'Your server returned a web page instead of audio. Check '
          'Cloudflare/Jellyfin access.',
          kind: PlaybackResolutionErrorKind.serverReturnedWebPage,
        );
      case JellyfinErrorKind.notAudioStream:
        return const PlaybackResolutionException(
          'Jellyfin did not return an audio stream.',
          kind: PlaybackResolutionErrorKind.invalidStream,
        );
      case JellyfinErrorKind.unsupportedResponse:
        return const PlaybackResolutionException(
          'Your Jellyfin server returned a response Linthra could not use. '
          'It may be running an unsupported version.',
          kind: PlaybackResolutionErrorKind.invalidStream,
        );
      case JellyfinErrorKind.streamUnavailable:
        return const PlaybackResolutionException(
          "This track isn't available to stream from your server right now.",
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        );
      case JellyfinErrorKind.notReachable:
      case JellyfinErrorKind.serverError:
        return const PlaybackResolutionException(
          "Couldn't reach your Jellyfin server.",
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
      case JellyfinErrorKind.invalidUrl:
      case JellyfinErrorKind.unexpected:
        return const PlaybackResolutionException(
          "Couldn't stream this track.",
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        );
    }
  }
}
