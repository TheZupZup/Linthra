import '../../models/playback_source.dart';
import '../../models/track.dart';
import '../../services/playable_uri_resolver.dart';
import 'plex_exception.dart';
import 'plex_stream_source.dart';
import 'plex_track_mapper.dart';

/// Resolves Plex tracks to authenticated streaming URLs at play time.
///
/// The `X-Plex-Token` is woven into the URL here, on demand by the
/// [PlexStreamSource], and never stored on the track or in the catalog — a
/// Plex stream URL carries the token in its **query**, so persisting one would
/// persist the credential (see docs/plex.md → Token safety rules). Before
/// minting, this verifies the session is still valid and the server reachable,
/// so the player can show a precise, friendly error instead of an opaque
/// audio-engine failure. The minted URL is returned to the controller and
/// handed to the engine — never logged, never placed in [Track].
///
/// The current signed-in source is read through a getter so signing in or out
/// is reflected without rebuilding the controller; with no Plex session every
/// `plex:` track resolves to a friendly "not signed in" — recognized, but
/// unavailable. The resolver depends only on the narrow [PlexStreamSource],
/// never on Riverpod or HTTP.
class PlexPlayableUriResolver implements PlayableUriResolver {
  const PlexPlayableUriResolver(this._source);

  /// Supplies the current signed-in source, or `null` when not connected.
  final PlexStreamSource? Function() _source;

  @override
  bool handles(Track track) => track.uri.startsWith(PlexTrackMapper.uriScheme);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final PlexStreamSource? source = _source();
    if (source == null) {
      throw const PlaybackResolutionException(
        'Connect to your Plex server in Settings before streaming this track.',
        kind: PlaybackResolutionErrorKind.notSignedIn,
      );
    }

    // Confirm the session still works, then mint the stream URL — both can
    // throw a typed [PlexException], which becomes a precise, secret-free
    // message rather than the engine's opaque "couldn't play".
    final Uri? uri;
    try {
      await source.verifyReachable();
      uri = await source.resolvePlayableUri(track);
    } on PlexException catch (error) {
      throw _mapFailure(error);
    }

    if (uri == null) {
      // A null is precise, not vague: the lookup *succeeded* but the item
      // carries no Part — there is no file to direct-play (phase 1 has no
      // transcode fallback) — so say that instead of a generic "couldn't
      // stream" that reads like a network failure.
      throw const PlaybackResolutionException(
        'This track has no playable file on your Plex server.',
        kind: PlaybackResolutionErrorKind.streamUnavailable,
      );
    }
    return ResolvedPlayable(uri, PlaybackSource.streamingDirect);
  }

  /// Maps a Plex failure to a friendly, secret-free playback error. Branches
  /// on [PlexErrorKind] so wording can change without breaking it, and so a
  /// new kind is a compile error here rather than a silent generic message.
  PlaybackResolutionException _mapFailure(PlexException error) {
    switch (error.kind) {
      case PlexErrorKind.unauthorized:
        // Plex has no sign-in here — the user pastes a token — so steer to the
        // connect flow, matching the Settings/sync wording.
        return const PlaybackResolutionException(
          'Your Plex session was rejected by the server. Connect again in '
          'Settings with a new token.',
          kind: PlaybackResolutionErrorKind.sessionExpired,
        );
      case PlexErrorKind.notPlex:
        return const PlaybackResolutionException(
          'Your server returned a web page instead of audio. Check your '
          'reverse proxy / server address.',
          kind: PlaybackResolutionErrorKind.serverReturnedWebPage,
        );
      case PlexErrorKind.notFound:
        return const PlaybackResolutionException(
          "This track isn't available from your Plex server right now.",
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        );
      case PlexErrorKind.unsupportedResponse:
        return const PlaybackResolutionException(
          'Your Plex server returned a response Linthra could not use. '
          'It may be running an unsupported version.',
          kind: PlaybackResolutionErrorKind.invalidStream,
        );
      case PlexErrorKind.notReachable:
      case PlexErrorKind.serverError:
        return const PlaybackResolutionException(
          "Couldn't reach your Plex server.",
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
      case PlexErrorKind.invalidUrl:
      case PlexErrorKind.unexpected:
        return const PlaybackResolutionException(
          "Couldn't stream this track.",
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        );
    }
  }
}
