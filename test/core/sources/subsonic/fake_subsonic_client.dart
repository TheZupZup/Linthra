import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';

/// A configurable [SubsonicClient] that returns canned responses (or throws)
/// and records what it was asked, so the source/authenticator/controllers can
/// be tested without a real server or HTTP.
class FakeSubsonicClient implements SubsonicClient {
  FakeSubsonicClient({
    this.serverInfo,
    this.pingError,
    this.verifyError,
    this.artists = const <SubsonicArtistDto>[],
    this.albums = const <SubsonicAlbumDto>[],
    this.songsByAlbum = const <String, List<SubsonicSongDto>>{},
    this.listError,
    this.streamProbe,
    this.probeError,
  });

  SubsonicServerInfo? serverInfo;
  SubsonicException? pingError;
  SubsonicException? verifyError;
  List<SubsonicArtistDto> artists;
  List<SubsonicAlbumDto> albums;
  Map<String, List<SubsonicSongDto>> songsByAlbum;
  SubsonicException? listError;

  /// Canned probe; defaults to a healthy `audio/mpeg` 200.
  SubsonicStreamProbe? streamProbe;
  SubsonicException? probeError;

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastUsername;
  SubsonicCredentials? lastCredentials;
  int verifyCount = 0;
  final List<String> requestedAlbumIds = <String>[];
  Uri? lastProbedUrl;

  @override
  Future<SubsonicServerInfo> ping(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
  }) async {
    lastBaseUrl = baseUrl;
    lastUsername = username;
    lastCredentials = credentials;
    final SubsonicException? error = pingError;
    if (error != null) throw error;
    return serverInfo ??
        const SubsonicServerInfo(
          apiVersion: '1.16.1',
          type: 'navidrome',
          serverVersion: '0.52.0',
        );
  }

  @override
  Future<void> verifySession(SubsonicSession session) async {
    verifyCount++;
    final SubsonicException? error = verifyError;
    if (error != null) throw error;
  }

  @override
  Future<List<SubsonicArtistDto>> getArtists(SubsonicSession session) async {
    final SubsonicException? error = listError;
    if (error != null) throw error;
    return artists;
  }

  @override
  Future<List<SubsonicAlbumDto>> getAlbums(SubsonicSession session) async {
    final SubsonicException? error = listError;
    if (error != null) throw error;
    return albums;
  }

  @override
  Future<List<SubsonicSongDto>> getAlbumSongs(
    SubsonicSession session,
    String albumId,
  ) async {
    requestedAlbumIds.add(albumId);
    final SubsonicException? error = listError;
    if (error != null) throw error;
    return songsByAlbum[albumId] ?? const <SubsonicSongDto>[];
  }

  @override
  Future<SubsonicStreamProbe> probeStream(Uri url) async {
    lastProbedUrl = url;
    final SubsonicException? error = probeError;
    if (error != null) throw error;
    return streamProbe ??
        const SubsonicStreamProbe(statusCode: 200, contentType: 'audio/mpeg');
  }
}
