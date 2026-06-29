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
  static const String _playlistsPath = '/Playlists';
  static const String _playingPath = '/Sessions/Playing';
  static const String _playingProgressPath = '/Sessions/Playing/Progress';
  static const String _playingStoppedPath = '/Sessions/Playing/Stopped';
  static const String _capabilitiesFullPath = '/Sessions/Capabilities/Full';
  static const String _socketPath = '/socket';

  // --- Query-parameter keys, named once so a typo can't split a request. ---

  /// The query-parameter name that carries the access token in a media URL —
  /// the stream, download, and control-socket URLs — instead of an
  /// `Authorization` header, because that is what the Android audio engine
  /// (`just_audio`/ExoPlayer) fetches with, and query auth survives the
  /// redirects a stripped header would not.
  ///
  /// This is the PascalCase `ApiKey`: Jellyfin's canonical, non-legacy query
  /// key, read unconditionally across the 10.x line *and* Jellyfin 12. The
  /// lowercase `api_key` (and the `X-Emby-*` headers) is a legacy form Jellyfin
  /// 12 only honours when the server opts back in with `EnableLegacyAuthorization`
  /// — off by default — so an `api_key` media URL would arrive unauthenticated
  /// (401) on a stock Jellyfin 12 server while `ApiKey` keeps working. `ApiKey`
  /// has been accepted since well before 10.8, so this is also fully backward
  /// compatible. See docs/jellyfin-compatibility.md.
  static const String apiKeyParam = 'ApiKey';

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
  ///
  /// [startIndex] and [limit] page the listing (`StartIndex`/`Limit`, the
  /// standard Jellyfin paging params) so a large library is pulled in bounded
  /// chunks rather than one unbounded request that can time out on a big/slow
  /// server. They are stable across the 10.x line and ignored by servers that
  /// don't paginate, so adding them is always safe.
  static Uri items(
    String baseUrl, {
    required String userId,
    required JellyfinItemKind kind,
    int? startIndex,
    int? limit,
  }) {
    final Map<String, String> paging = <String, String>{
      if (startIndex != null) 'StartIndex': '$startIndex',
      if (limit != null) 'Limit': '$limit',
    };
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
            ...paging,
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
            ...paging,
          },
        );
      case JellyfinItemKind.artist:
        return _join(baseUrl, _artistsPath).replace(
          queryParameters: <String, String>{
            userIdParam: userId,
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
            ...paging,
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

  /// `GET /Items?…&IncludeItemTypes=Playlist` — the user's playlists. Images are
  /// disabled to keep the payload small; only id + name are mapped.
  static Uri playlists(String baseUrl, {required String userId}) =>
      _join(baseUrl, _itemsPath).replace(
        queryParameters: <String, String>{
          userIdParam: userId,
          'Recursive': 'true',
          'IncludeItemTypes': 'Playlist',
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
          'EnableImages': 'false',
        },
      );

  /// `GET /Playlists/<playlistId>/Items` — the ordered entries of one playlist.
  /// Each entry carries both the media `Id` and the playlist-scoped
  /// `PlaylistItemId` (the entry id needed to remove it).
  static Uri playlistItems(
    String baseUrl, {
    required String playlistId,
    required String userId,
  }) =>
      _join(baseUrl, '$_playlistsPath/$playlistId/Items').replace(
        queryParameters: <String, String>{
          userIdParam: userId,
          'Fields': 'ItemCounts',
        },
      );

  /// `POST /Playlists?Name=…&Ids=…&UserId=…` — create a playlist (optionally
  /// seeded with audio item [itemIds]). Returns `{ "Id": "<playlistId>" }`.
  static Uri createPlaylist(
    String baseUrl, {
    required String name,
    required String userId,
    List<String> itemIds = const <String>[],
  }) {
    final Map<String, String> query = <String, String>{
      'Name': name,
      userIdParam: userId,
      'MediaType': 'Audio',
    };
    if (itemIds.isNotEmpty) {
      query['Ids'] = itemIds.join(',');
    }
    return _join(baseUrl, _playlistsPath).replace(queryParameters: query);
  }

  /// `POST /Playlists/<playlistId>/Items?Ids=…&UserId=…` — append audio
  /// [itemIds] to an existing playlist.
  static Uri addPlaylistItems(
    String baseUrl, {
    required String playlistId,
    required String userId,
    required List<String> itemIds,
  }) =>
      _join(baseUrl, '$_playlistsPath/$playlistId/Items').replace(
        queryParameters: <String, String>{
          'Ids': itemIds.join(','),
          userIdParam: userId,
        },
      );

  /// `DELETE /Playlists/<playlistId>/Items?EntryIds=…` — remove entries by their
  /// playlist-scoped entry ids (the `PlaylistItemId`s, not the media ids).
  static Uri removePlaylistEntries(
    String baseUrl, {
    required String playlistId,
    required List<String> entryIds,
  }) =>
      _join(baseUrl, '$_playlistsPath/$playlistId/Items').replace(
        queryParameters: <String, String>{
          'EntryIds': entryIds.join(','),
        },
      );

  /// `DELETE /Items/<itemId>` — delete a library item. Used to delete a playlist
  /// (a playlist is an item); requires the user to have delete permission, so a
  /// 401/403 is mapped to a friendly "couldn't delete" rather than retried.
  static Uri deleteItem(String baseUrl, {required String itemId}) =>
      _join(baseUrl, '$_itemsPath/$itemId');

  /// `POST /Sessions/Playing` — report that playback of an item started. The
  /// item and position ride in the JSON body; the session this player shows up
  /// as on the server's dashboard is keyed off the `Authorization` header's
  /// client/device identity, so the URL itself carries nothing.
  static Uri playbackStarted(String baseUrl) => _join(baseUrl, _playingPath);

  /// `POST /Sessions/Playing/Progress` — report position (and the
  /// paused/playing flag) for the item already reported via [playbackStarted].
  static Uri playbackProgress(String baseUrl) =>
      _join(baseUrl, _playingProgressPath);

  /// `POST /Sessions/Playing/Stopped` — report that playback of an item ended,
  /// settling the server's session and play state for it.
  static Uri playbackStopped(String baseUrl) =>
      _join(baseUrl, _playingStoppedPath);

  /// `POST /Sessions/Capabilities/Full` — declares this client's session
  /// capabilities, so other Jellyfin apps list it as a controllable player.
  /// Linthra posts `SupportsMediaControl: true` here to receive the transport
  /// (Playstate) commands over the control socket; the token rides in the
  /// `Authorization` header, so this URL is token-free.
  static Uri capabilitiesFull(String baseUrl) =>
      _join(baseUrl, _capabilitiesFullPath);

  /// The session control WebSocket: `{ws|wss}://<host>/socket?ApiKey=…&deviceId=…`.
  ///
  /// Built from [baseUrl] by switching the scheme to `ws`/`wss`. The server
  /// pushes remote-control (Playstate/GeneralCommand) messages down this socket
  /// once the session is registered. Auth rides in the [accessToken] `ApiKey`
  /// query — exactly like the audio stream URL ([audioStream]) — so the receiver
  /// must treat this Uri as a secret and never log it.
  static Uri controlSocket(
    String baseUrl, {
    required String accessToken,
    required String deviceId,
  }) {
    final Uri http = Uri.parse('$baseUrl$_socketPath');
    final String wsScheme = http.scheme == 'https' ? 'wss' : 'ws';
    return http.replace(
      scheme: wsScheme,
      queryParameters: <String, String>{
        apiKeyParam: accessToken,
        'deviceId': deviceId,
      },
    );
  }

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

  /// The original-file download URL: `/Items/<id>/Download?ApiKey=…`, used so
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
