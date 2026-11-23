import '../../models/cast_media.dart';
import '../../models/track.dart';
import '../../services/cast/cast_media_access.dart';
import '../../services/cast/cast_media_resolver.dart';
import '../../services/playback_diagnostics.dart';
import 'subsonic_exception.dart';
import 'subsonic_stream_source.dart';
import 'subsonic_track_mapper.dart';

/// Resolves Subsonic/Navidrome tracks into [CastMedia] for a receiver to stream.
///
/// Reuses the same [SubsonicStreamSource] seam the audio engine's resolver uses
/// ([SubsonicStreamSource.verifyReachable] then
/// [SubsonicStreamSource.resolvePlayableUri]), so the cast URL is minted on
/// demand at cast time, with the salt+token woven in by the source and never
/// stored on the track or in the catalog. The receiver fetches that URL
/// directly, so a Subsonic track casts as a live stream — including one that
/// also has an offline copy, since a receiver can't read the on-device file but
/// can reach the server.
///
/// The minted URL is placed only on the returned [CastMedia], which is handed
/// straight to the cast session and never logged or persisted. The only thing
/// logged here is the secret-free [PlaybackDiagnostics] line.
class SubsonicCastMediaResolver implements CastMediaResolver {
  const SubsonicCastMediaResolver(this._source);

  /// Supplies the current signed-in source, or `null` when not connected.
  final SubsonicStreamSource? Function() _source;

  /// A best-effort MIME hint for the receiver. The stream serves a broadly
  /// compatible audio format; an exact per-track content type is a follow-up.
  static const String _defaultContentType = 'audio/mpeg';

  /// What casting a Subsonic/Navidrome track hands over.
  ///
  /// The Subsonic API authenticates every request, streaming included, with the
  /// user name plus a salted token derived from the password. It is a
  /// credential, not a capability: it is accepted on every endpoint, it does not
  /// expire, and it cannot be narrowed to one song. A receiver handed this URL
  /// can reach the whole account with it, which is also why the cover-art URL is
  /// never sent (it would carry the same credential for no playback benefit).
  ///
  /// Signing out in Linthra does not take it back either: the token is derived
  /// from the password, so only changing that password invalidates a copy
  /// somebody else kept.
  ///
  /// Navidrome and some other servers can issue their own shorter-lived tokens
  /// for their own clients, but not through the Subsonic API Linthra speaks; see
  /// docs/design/cast-media-access.md.
  static const CastMediaAccess access = CastMediaAccess(
    delegation: CastMediaDelegation.accountCredential,
    scope: CastMediaScope.account,
    summary: 'The receiver is given a Subsonic stream URL carrying the salted '
        'credential, which reaches the whole account and stays valid until the '
        'password changes.',
  );

  @override
  bool canCast(Track track) =>
      track.uri.startsWith(SubsonicTrackMapper.uriScheme);

  @override
  CastMediaAccess accessFor(Track track) =>
      canCast(track) ? access : CastMediaAccess.none;

  @override
  Future<CastMedia> resolve(Track track) async {
    final SubsonicStreamSource? source = _source();
    if (source == null) {
      throw const CastMediaException(
        'Sign in to your Subsonic/Navidrome server before casting this track.',
        kind: CastMediaErrorKind.notSignedIn,
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
      throw const CastMediaException(
        "Couldn't cast this track.",
        kind: CastMediaErrorKind.unavailable,
      );
    }

    // Secret-free: the diagnostics API cannot carry the credential or full URL.
    PlaybackDiagnostics.resolved(
      source: 'subsonicCast',
      resolver: 'SubsonicCastMediaResolver',
      itemId: track.id,
    );

    return CastMedia(
      url: uri,
      contentType: _defaultContentType,
      title: track.title,
      artist: track.artistName,
      album: track.albumName,
      duration: track.duration > Duration.zero ? track.duration : null,
      access: access,
      // Artwork is intentionally omitted: Subsonic's getCoverArt URL embeds the
      // salt+token, so sending it would leak the credential to the receiver.
    );
  }

  /// Maps a Subsonic failure to a friendly, secret-free cast error. A rejected
  /// session is worth distinguishing ("sign in again"); everything else
  /// collapses to a generic "couldn't cast".
  CastMediaException _mapFailure(SubsonicException error) {
    switch (error.kind) {
      case SubsonicErrorKind.unauthorized:
        return const CastMediaException(
          'Your Subsonic session was rejected. Sign in again to cast.',
          kind: CastMediaErrorKind.notSignedIn,
        );
      case SubsonicErrorKind.notSubsonic:
      case SubsonicErrorKind.streamUnavailable:
      case SubsonicErrorKind.unsupportedResponse:
      case SubsonicErrorKind.notReachable:
      case SubsonicErrorKind.cleartextBlocked:
      case SubsonicErrorKind.insecureConnection:
      case SubsonicErrorKind.serverError:
      case SubsonicErrorKind.invalidUrl:
      case SubsonicErrorKind.unexpected:
        return const CastMediaException(
          "Couldn't cast this track from your music server.",
          kind: CastMediaErrorKind.unavailable,
        );
    }
  }
}
