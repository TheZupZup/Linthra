import '../../models/cast_media.dart';
import '../../models/track.dart';
import '../../services/cast/cast_media_resolver.dart';
import '../../services/playback_diagnostics.dart';
import 'jellyfin_exception.dart';
import 'jellyfin_stream_source.dart';
import 'jellyfin_track_mapper.dart';

/// Resolves Jellyfin tracks into [CastMedia] for a receiver to stream.
///
/// It reuses the very same [JellyfinStreamSource] seam the audio engine's
/// resolver uses ([JellyfinStreamSource.verifyReachable] then
/// [JellyfinStreamSource.resolvePlayableUri]), so the cast URL is minted on
/// demand at cast time, with the token woven in by the source and never stored
/// on the track or in the catalog. The receiver fetches that URL directly, so a
/// Jellyfin track casts as a live stream — including one that also has an
/// offline copy, since a receiver can't read the on-device file but can reach
/// the server.
///
/// The minted URL (token and all) is placed only on the returned [CastMedia],
/// which is handed straight to the cast session and never logged or persisted.
/// The only thing logged here is the secret-free [PlaybackDiagnostics] line,
/// whose API has no parameter for a token or full URL.
class JellyfinCastMediaResolver implements CastMediaResolver {
  const JellyfinCastMediaResolver(this._source);

  /// Supplies the current signed-in source, or `null` when not connected.
  final JellyfinStreamSource? Function() _source;

  /// A best-effort MIME hint for the receiver. The stream serves the original
  /// file bytes (`static=true`), whose container we don't track, so we send the
  /// most common audio type; broadly compatible formats (MP3/AAC) play, and a
  /// transcoded cast profile for exotic codecs is a documented follow-up.
  static const String _defaultContentType = 'audio/mpeg';

  @override
  bool canCast(Track track) =>
      track.uri.startsWith(JellyfinTrackMapper.uriScheme);

  @override
  Future<CastMedia> resolve(Track track) async {
    final JellyfinStreamSource? source = _source();
    if (source == null) {
      throw const CastMediaException(
        'Sign in to Jellyfin before casting this track.',
        kind: CastMediaErrorKind.notSignedIn,
      );
    }

    final Uri? uri;
    try {
      await source.verifyReachable();
      uri = await source.resolvePlayableUri(track);
    } on JellyfinException catch (error) {
      throw _mapFailure(error);
    }
    if (uri == null) {
      throw const CastMediaException(
        "Couldn't cast this track.",
        kind: CastMediaErrorKind.unavailable,
      );
    }

    // Secret-free: the diagnostics API cannot carry the token or full URL.
    PlaybackDiagnostics.resolved(
      source: 'jellyfinCast',
      resolver: 'JellyfinCastMediaResolver',
      itemId: track.id,
    );

    return CastMedia(
      url: uri,
      contentType: _defaultContentType,
      title: track.title,
      artist: track.artistName,
      album: track.albumName,
      duration: track.duration > Duration.zero ? track.duration : null,
      // Token-free per JellyfinEndpoints.primaryImage, so safe to send as-is.
      artworkUrl: track.artworkUri,
    );
  }

  /// Maps a Jellyfin failure to a friendly, secret-free cast error. An expired
  /// session is the one case worth distinguishing for the user ("sign in
  /// again"); everything else collapses to a generic "couldn't cast".
  CastMediaException _mapFailure(JellyfinException error) {
    switch (error.kind) {
      case JellyfinErrorKind.unauthorized:
        return const CastMediaException(
          'Your Jellyfin session expired. Sign in again to cast.',
          kind: CastMediaErrorKind.notSignedIn,
        );
      case JellyfinErrorKind.webPage:
      case JellyfinErrorKind.notJellyfin:
      case JellyfinErrorKind.notAudioStream:
      case JellyfinErrorKind.unsupportedResponse:
      case JellyfinErrorKind.streamUnavailable:
      case JellyfinErrorKind.notReachable:
      case JellyfinErrorKind.serverError:
      case JellyfinErrorKind.invalidUrl:
      case JellyfinErrorKind.unexpected:
        return const CastMediaException(
          "Couldn't cast this track from your Jellyfin server.",
          kind: CastMediaErrorKind.unavailable,
        );
    }
  }
}
