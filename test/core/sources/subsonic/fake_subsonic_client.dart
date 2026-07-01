import 'package:linthra/core/models/lyrics.dart';
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

  /// Canned lyrics for [fetchLyrics]; `null` models "no lyrics".
  Lyrics? lyrics;
  SubsonicException? lyricsError;

  /// When set, every [scrobble] call throws it (after being recorded), so
  /// reporters can prove failures are swallowed. Set [scrobbleError] for a
  /// typed failure or [scrobbleUnexpectedError] for an untyped one.
  SubsonicException? scrobbleError;
  Object? scrobbleUnexpectedError;

  /// Every scrobble call received, in order, so tests can assert the exact
  /// now-playing/submission sequence a playback scenario produced.
  final List<({String songId, bool submission})> scrobbles =
      <({String songId, bool submission})>[];

  /// The session the last [scrobble] call carried, so a test can prove the
  /// live (current) session was used.
  SubsonicSession? lastScrobbleSession;

  /// The server's starred song ids for [getStarredSongIds].
  Set<String> starredSongIds = <String>{};

  /// When set, favourite reads/writes ([getStarredSongIds]/[star]/[unstar])
  /// throw it, so callers can prove failures are handled.
  SubsonicException? favoritesError;

  /// Every star/unstar call, in order, so a test can assert the exact requests.
  final List<({String songId, bool starred})> starCalls =
      <({String songId, bool starred})>[];

  /// The server's playlists (headers) for [getPlaylists], and their ordered
  /// song ids for [getPlaylistSongIds], keyed by playlist id.
  List<SubsonicPlaylistDto> playlists = <SubsonicPlaylistDto>[];
  Map<String, List<String>> playlistSongIds = <String, List<String>>{};

  /// When set, playlist reads/writes throw it.
  SubsonicException? playlistError;

  /// The id [createPlaylist] returns (and records the create under). Defaults to
  /// a stable value so a single create is easy to assert.
  String createdPlaylistId = 'pl-new';

  /// Recorded playlist writes, in order.
  final List<({String? name, String? playlistId, List<String> songIds})>
      createCalls =
      <({String? name, String? playlistId, List<String> songIds})>[];
  final List<({String playlistId, List<String> songIds})> setSongsCalls =
      <({String playlistId, List<String> songIds})>[];
  final List<({String playlistId, String name})> renameCalls =
      <({String playlistId, String name})>[];
  final List<String> deletedPlaylistIds = <String>[];

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastUsername;
  SubsonicCredentials? lastCredentials;
  int verifyCount = 0;
  final List<String> requestedAlbumIds = <String>[];
  Uri? lastProbedUrl;
  String? lastLyricsSongId;
  String? lastLyricsArtist;
  String? lastLyricsTitle;

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
  Future<Lyrics?> fetchLyrics(
    SubsonicSession session,
    String songId, {
    String? artist,
    String? title,
  }) async {
    lastLyricsSongId = songId;
    lastLyricsArtist = artist;
    lastLyricsTitle = title;
    final SubsonicException? error = lyricsError;
    if (error != null) throw error;
    return lyrics;
  }

  @override
  Future<SubsonicStreamProbe> probeStream(Uri url) async {
    lastProbedUrl = url;
    final SubsonicException? error = probeError;
    if (error != null) throw error;
    return streamProbe ??
        const SubsonicStreamProbe(statusCode: 200, contentType: 'audio/mpeg');
  }

  @override
  Future<void> scrobble(
    SubsonicSession session,
    String songId, {
    required bool submission,
  }) async {
    lastScrobbleSession = session;
    scrobbles.add((songId: songId, submission: submission));
    final SubsonicException? error = scrobbleError;
    if (error != null) throw error;
    final Object? unexpected = scrobbleUnexpectedError;
    if (unexpected != null) throw unexpected;
  }

  @override
  Future<Set<String>> getStarredSongIds(SubsonicSession session) async {
    final SubsonicException? error = favoritesError;
    if (error != null) throw error;
    return <String>{...starredSongIds};
  }

  @override
  Future<void> star(SubsonicSession session, String songId) async {
    starCalls.add((songId: songId, starred: true));
    final SubsonicException? error = favoritesError;
    if (error != null) throw error;
    starredSongIds.add(songId);
  }

  @override
  Future<void> unstar(SubsonicSession session, String songId) async {
    starCalls.add((songId: songId, starred: false));
    final SubsonicException? error = favoritesError;
    if (error != null) throw error;
    starredSongIds.remove(songId);
  }

  @override
  Future<List<SubsonicPlaylistDto>> getPlaylists(
    SubsonicSession session,
  ) async {
    final SubsonicException? error = playlistError;
    if (error != null) throw error;
    return <SubsonicPlaylistDto>[...playlists];
  }

  @override
  Future<List<String>> getPlaylistSongIds(
    SubsonicSession session,
    String playlistId,
  ) async {
    final SubsonicException? error = playlistError;
    if (error != null) throw error;
    return <String>[...?playlistSongIds[playlistId]];
  }

  @override
  Future<String> createPlaylist(
    SubsonicSession session, {
    required String name,
    List<String> songIds = const <String>[],
  }) async {
    createCalls.add((name: name, playlistId: null, songIds: songIds));
    final SubsonicException? error = playlistError;
    if (error != null) throw error;
    playlists.add(SubsonicPlaylistDto(id: createdPlaylistId, name: name));
    playlistSongIds[createdPlaylistId] = <String>[...songIds];
    return createdPlaylistId;
  }

  @override
  Future<void> setPlaylistSongs(
    SubsonicSession session,
    String playlistId,
    List<String> songIds,
  ) async {
    setSongsCalls.add((playlistId: playlistId, songIds: songIds));
    final SubsonicException? error = playlistError;
    if (error != null) throw error;
    playlistSongIds[playlistId] = <String>[...songIds];
  }

  @override
  Future<void> renamePlaylist(
    SubsonicSession session,
    String playlistId,
    String name,
  ) async {
    renameCalls.add((playlistId: playlistId, name: name));
    final SubsonicException? error = playlistError;
    if (error != null) throw error;
  }

  @override
  Future<void> deletePlaylist(
    SubsonicSession session,
    String playlistId,
  ) async {
    deletedPlaylistIds.add(playlistId);
    final SubsonicException? error = playlistError;
    if (error != null) throw error;
    playlists = <SubsonicPlaylistDto>[
      for (final SubsonicPlaylistDto p in playlists)
        if (p.id != playlistId) p,
    ];
    playlistSongIds.remove(playlistId);
  }
}
