import 'jellyfin_api.dart';

/// Every Jellyfin REST path and URL Linthra builds, in one place.
///
/// Centralizing the endpoints means:
///  - the HTTP client, the music source, and the track mapper never embed raw
///    path strings, so a path can't quietly drift between two call sites;
///  - the exact set of endpoints Linthra depends on is auditable from this one
///    file (kept in sync with docs/jellyfin-compatibility.md);
///  - the token-bearing stream and download URLs are built by the same pure,
///    tested helpers, so the "weave the token into the query, on demand, never
///    store it" rule lives in a single spot.
///
/// All builders are pure: they take a clean base URL (no trailing slash, as
/// produced by [JellyfinServerUrl.normalize]) plus the ids/params they need and
/// return a [Uri]. Nothing here performs I/O, logs, or holds state.
///
/// Compatibility: these paths are stable across the Jellyfin 10.x line. If a
/// future server version relocates one, change it here — and only here — and
/// note it in the compatibility doc.
abstract final class JellyfinEndpoints {
  // --- Path templates: the only place these strings are written. ---
  static const String _serverInfoPath = '/System/Info/Public';
  static const String _authenticateByNamePath = '/Users/AuthenticateByName';
  static const String _currentUserPath = '/Users/Me';
  static const String _itemsPath = '/Items';
  static const String _artistsPath = '/Artists';

  // --- Query-parameter keys, named once so a typo can't split a request. ---

  /// The access token, carried in a media URL's query (not an `Authorization`
  /// header) so it survives the redirects a stripped header would not and
  /// matches exactly what the audio engine fetches with.
  static const String apiKeyParam = 'api_key';

  /// `static=true` asks Jellyfin to serve the original file bytes as-is.
  static const String staticParam = 'static';
  static const String userIdParam = 'UserId';
  static const String deviceIdParam = 'DeviceId';

  /// `GET /System/Info/Public` — public server info. No credentials required;
  /// backs "Test connection" and the version/capability read.
  static Uri serverInfo(String baseUrl) => _join(baseUrl, _serverInfoPath);

  /// `POST /Users/AuthenticateByName` — exchange a username + password for an
  /// access token.
  static Uri authenticateByName(String baseUrl) =>
      _join(baseUrl, _authenticateByNamePath);

  /// `GET /Users/Me` — the tiny authenticated call used to verify a session is
  /// still accepted (a 401 means the token expired).
  static Uri currentUser(String baseUrl) => _join(baseUrl, _currentUserPath);

  /// The library-listing URL for one [kind] and [userId].
  ///
  /// Audio and albums share `/Items` filtered by type; artists have their own
  /// `/Artists` endpoint. The sort/field choices match what Linthra maps.
  static Uri items(
    String baseUrl, {
    required String userId,
    required JellyfinItemKind kind,
  }) {
    switch (kind) {
      case JellyfinItemKind.audio:
        return _join(baseUrl, _itemsPath).replace(
          queryParameters: <String, String>{
            userIdParam: userId,
            'Recursive': 'true',
            'IncludeItemTypes': 'Audio',
            'SortBy': 'AlbumArtist,Album,IndexNumber,SortName',
            'SortOrder': 'Ascending',
            'Fields': 'RunTimeTicks',
          },
        );
      case JellyfinItemKind.album:
        return _join(baseUrl, _itemsPath).replace(
          queryParameters: <String, String>{
            userIdParam: userId,
            'Recursive': 'true',
            'IncludeItemTypes': 'MusicAlbum',
            'SortBy': 'AlbumArtist,SortName',
            'SortOrder': 'Ascending',
            'Fields': 'ProductionYear,ChildCount',
          },
        );
      case JellyfinItemKind.artist:
        return _join(baseUrl, _artistsPath).replace(
          queryParameters: <String, String>{
            userIdParam: userId,
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
          },
        );
    }
  }

  /// `GET /Items?…&Filters=IsFavorite` — the favourite audio item ids for
  /// [userId]. Images are disabled to keep the payload small.
  static Uri favoriteAudioItems(String baseUrl, {required String userId}) =>
      _join(baseUrl, _itemsPath).replace(
        queryParameters: <String, String>{
          userIdParam: userId,
          'Recursive': 'true',
          'IncludeItemTypes': 'Audio',
          'Filters': 'IsFavorite',
          'EnableImages': 'false',
        },
      );

  /// `/Users/<userId>/FavoriteItems/<itemId>` — `POST` to mark, `DELETE` to
  /// clear a favourite.
  static Uri favoriteItem(
    String baseUrl, {
    required String userId,
    required String itemId,
  }) =>
      _join(baseUrl, '/Users/$userId/FavoriteItems/$itemId');

  /// `GET /Audio/<itemId>/Lyrics` — time-synced or plain lyrics (a 404 just
  /// means the server has none).
  static Uri lyrics(String baseUrl, {required String itemId}) =>
      _join(baseUrl, '/Audio/$itemId/Lyrics');

  /// `GET /Items/<itemId>/Images/Primary` — the token-free cover-art URL. Needs
  /// no auth, so it is safe to persist on a track and cache.
  static Uri primaryImage(String baseUrl, {required String itemId}) =>
      _join(baseUrl, '/Items/$itemId/Images/Primary');

  /// The direct-play audio stream URL: `/Audio/<id>/stream?static=true&…`.
  ///
  /// `static=true` requests the original file bytes (the reliable direct-stream
  /// path `just_audio`/ExoPlayer can open) rather than a negotiated
  /// transcode/HLS variant the engine may reject. The token rides in
  /// [apiKeyParam]; it is woven in here, on demand, and never stored on the
  /// track or in the catalog.
  static Uri audioStream(
    String baseUrl, {
    required String itemId,
    required String accessToken,
    required String userId,
    required String deviceId,
  }) =>
      _join(baseUrl, '/Audio/$itemId/stream').replace(
        queryParameters: <String, String>{
          staticParam: 'true',
          apiKeyParam: accessToken,
          userIdParam: userId,
          deviceIdParam: deviceId,
        },
      );

  /// The original-file download URL: `/Items/<id>/Download?api_key=…`, used so
  /// the offline copy is the real source file rather than a transcode. Like
  /// [audioStream], the token is woven in on demand and never stored.
  static Uri download(
    String baseUrl, {
    required String itemId,
    required String accessToken,
  }) =>
      _join(baseUrl, '/Items/$itemId/Download').replace(
        queryParameters: <String, String>{
          apiKeyParam: accessToken,
        },
      );

  static Uri _join(String baseUrl, String path) => Uri.parse('$baseUrl$path');
}
