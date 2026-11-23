import '../../models/cast_media.dart';
import '../../models/track.dart';
import '../../services/cast/cast_media_access.dart';
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

  /// What casting a Jellyfin track hands over.
  ///
  /// Jellyfin authenticates a stream request with the session's access token —
  /// the same token the app uses for everything else — carried in the URL's
  /// `api_key`, because that is the only authentication its stream endpoint
  /// accepts for a client that is not sending headers. There is no per-item
  /// signed URL, no scoped download token, and no server-side expiry to ask for
  /// in the stable API, so a receiver handed this URL is handed account-level
  /// access.
  ///
  /// How long that access lasts is not the app's to say. Signing out of
  /// Jellyfin in Linthra forgets the token on this device; it does not ask the
  /// server to invalidate it, so a receiver that kept the URL keeps working
  /// until the user revokes that device in Jellyfin, or the server expires it
  /// on its own terms. Recording the lifetime as "until the user signs out"
  /// would be the comfortable answer and the wrong one.
  ///
  /// Declaring that plainly is the point: pretending a token in a query string
  /// is a capability would be inventing a restriction the server does not
  /// enforce. What Jellyfin would need for [CastMediaDelegation.scopedCapability]
  /// is in docs/design/cast-media-access.md.
  static const CastMediaAccess access = CastMediaAccess(
    delegation: CastMediaDelegation.accountCredential,
    scope: CastMediaScope.account,
    summary: 'The receiver is given a Jellyfin stream URL carrying the session '
        'access token, which reaches the whole account and keeps working until '
        'the server revokes it.',
  );

  @override
  bool canCast(Track track) =>
      track.uri.startsWith(JellyfinTrackMapper.uriScheme);

  @override
  CastMediaAccess accessFor(Track track) =>
      canCast(track) ? access : CastMediaAccess.none;

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
      access: access,
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
