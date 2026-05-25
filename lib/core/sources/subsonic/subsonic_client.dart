import '../../models/subsonic_session.dart';
import 'subsonic_api.dart';
import 'subsonic_auth.dart';

/// The single seam through which Linthra talks HTTP to a Subsonic-compatible
/// server (such as Navidrome).
///
/// Every request goes through this interface, so the rest of the app
/// (authenticator, source, settings) depends only on it — never on `http`,
/// URLs, the auth query, or JSON. That keeps networking swappable and lets
/// tests drive the whole feature with a fake client and canned responses.
///
/// Implementations throw a [SubsonicException] (with a friendly message and a
/// [SubsonicErrorKind]) for every failure — including a Subsonic error returned
/// *inside a 200 response* — and must never put the password, salt, or token
/// into an exception, log, or any other output.
abstract interface class SubsonicClient {
  /// Confirms [baseUrl] is a reachable Subsonic server that accepts the given
  /// credentials, returning its public info. Backs "Test connection" and the
  /// credential check at sign-in.
  Future<SubsonicServerInfo> ping(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
  });

  /// Confirms [session] is still accepted by the server (its credential is
  /// valid and the server reachable) without fetching anything large. Backs the
  /// pre-stream check the playback resolver runs.
  Future<void> verifySession(SubsonicSession session);

  /// The ID3 artist index for the signed-in user.
  Future<List<SubsonicArtistDto>> getArtists(SubsonicSession session);

  /// The full ID3 album list, paginated internally so the caller gets every
  /// album in one call.
  Future<List<SubsonicAlbumDto>> getAlbums(SubsonicSession session);

  /// The songs of one album.
  Future<List<SubsonicSongDto>> getAlbumSongs(
    SubsonicSession session,
    String albumId,
  );

  /// Probes a minted stream [url] with a tiny ranged request to confirm the
  /// server returns playable audio *before* the URL is handed to the audio
  /// engine, returning the observed status and content type. The [url] carries
  /// the credential, so it must never be logged or placed in a thrown error;
  /// only a transport failure throws (a non-2xx status is returned for the
  /// caller to classify).
  Future<SubsonicStreamProbe> probeStream(Uri url);
}
