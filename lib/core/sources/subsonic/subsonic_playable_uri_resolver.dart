import '../../models/playback_source.dart';
import '../../models/track.dart';
import '../../services/playable_uri_resolver.dart';
import 'subsonic_exception.dart';
import 'subsonic_stream_source.dart';
import 'subsonic_track_mapper.dart';

/// Resolves Subsonic/Navidrome tracks to authenticated streaming URLs at play
/// time.
///
/// The salt+token is woven into the URL here, on demand by the
/// [SubsonicStreamSource], and never stored on the track or in the catalog.
/// Before minting, this verifies the session is still valid and the server
/// reachable, so the player can show a precise, friendly error instead of an
/// opaque audio-engine failure. The minted URL is returned to the controller
/// and handed to the engine — never logged, never placed in [Track].
///
/// The current signed-in source is read through a getter so signing in or out
/// is reflected without rebuilding the controller; the resolver depends only on
/// the narrow [SubsonicStreamSource], never on Riverpod or HTTP.
class SubsonicPlayableUriResolver implements PlayableUriResolver {
  const SubsonicPlayableUriResolver(this._source);

  /// Supplies the current signed-in source, or `null` when not connected.
  final SubsonicStreamSource? Function() _source;

  @override
  bool handles(Track track) =>
      track.uri.startsWith(SubsonicTrackMapper.uriScheme);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final SubsonicStreamSource? source = _source();
    if (source == null) {
      throw const PlaybackResolutionException(
        'Sign in to your Subsonic/Navidrome server before streaming this track.',
        kind: PlaybackResolutionErrorKind.notSignedIn,
      );
    }

    final Uri? uri;
    try {
      await source.verifyReachable();
      uri = await source.resolvePlayableUri(track);
    } on SubsonicException catch (error) {
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

  /// Maps a Subsonic failure to a friendly, secret-free playback error. Branches
  /// on [SubsonicErrorKind] so wording can change without breaking it, and so a
  /// new kind is a compile error here rather than a silent generic message.
  PlaybackResolutionException _mapFailure(SubsonicException error) {
    switch (error.kind) {
      case SubsonicErrorKind.unauthorized:
        return const PlaybackResolutionException(
          'Your Subsonic session was rejected. Sign in again.',
          kind: PlaybackResolutionErrorKind.sessionExpired,
        );
      case SubsonicErrorKind.notSubsonic:
        return const PlaybackResolutionException(
          'Your server returned a web page instead of audio. Check your '
          'reverse proxy / Cloudflare access.',
          kind: PlaybackResolutionErrorKind.serverReturnedWebPage,
        );
      case SubsonicErrorKind.streamUnavailable:
        return const PlaybackResolutionException(
          "This track isn't available from your server right now.",
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        );
      case SubsonicErrorKind.unsupportedResponse:
        return const PlaybackResolutionException(
          'Your music server returned a response Linthra could not use. '
          'It may be running an unsupported version.',
          kind: PlaybackResolutionErrorKind.invalidStream,
        );
      case SubsonicErrorKind.notReachable:
      case SubsonicErrorKind.serverError:
        return const PlaybackResolutionException(
          "Couldn't reach your music server.",
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
      case SubsonicErrorKind.cleartextBlocked:
      case SubsonicErrorKind.insecureConnection:
        return const PlaybackResolutionException(
          "Couldn't make a secure connection to your music server.",
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
      case SubsonicErrorKind.invalidUrl:
      case SubsonicErrorKind.unexpected:
        return const PlaybackResolutionException(
          "Couldn't stream this track.",
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        );
    }
  }
}
