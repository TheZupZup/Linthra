import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';

/// A configurable [JellyfinClient] that returns canned responses (or throws)
/// and records what it was asked, so the source/authenticator can be tested
/// without a real server or HTTP.
class FakeJellyfinClient implements JellyfinClient {
  FakeJellyfinClient({
    this.serverInfo,
    this.authResult,
    this.itemsByKind = const <JellyfinItemKind, List<JellyfinItemDto>>{},
    this.serverInfoError,
    this.authError,
    this.itemsError,
    this.verifyError,
    this.streamProbe,
    this.probeError,
  });

  JellyfinServerInfo? serverInfo;
  JellyfinAuthResult? authResult;
  Map<JellyfinItemKind, List<JellyfinItemDto>> itemsByKind;
  JellyfinException? serverInfoError;
  JellyfinException? authError;
  JellyfinException? itemsError;
  JellyfinException? verifyError;

  /// Canned result for [probeStream]; defaults to a healthy `audio/mpeg` 200 so
  /// tests that only care about the minted URL don't have to set it.
  JellyfinStreamProbe? streamProbe;

  /// A transport failure for [probeStream] to throw instead of returning.
  JellyfinException? probeError;

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastUsername;
  String? lastPassword;
  String? lastDeviceId;
  final List<JellyfinItemKind> requestedKinds = <JellyfinItemKind>[];
  int verifyCount = 0;

  /// The last URL [probeStream] was asked about, so a test can prove the probe
  /// ran against the minted stream URL.
  Uri? lastProbedUrl;

  /// Canned lyrics for [fetchLyrics]; `null` models "no lyrics" (a 404).
  Lyrics? lyrics;
  JellyfinException? lyricsError;
  String? lastLyricsItemId;

  /// Canned favourite ids for [fetchFavoriteIds] (also updated by [setFavorite]
  /// so a round-trip reads back consistently).
  Set<String> favoriteIds = <String>{};
  JellyfinException? favoritesError;

  /// Recorded favourite toggles in order, as (itemId, favorite) pairs.
  final List<({String itemId, bool favorite})> favoriteCalls =
      <({String itemId, bool favorite})>[];

  // --- Playlists ---------------------------------------------------------

  /// Canned playlists for [fetchPlaylists] (id + name).
  List<JellyfinPlaylistDto> playlists = <JellyfinPlaylistDto>[];

  /// Canned entries per playlist id for [fetchPlaylistEntries], also updated by
  /// the create/add/remove calls so a round-trip reads back consistently.
  final Map<String, List<JellyfinPlaylistEntry>> playlistEntries =
      <String, List<JellyfinPlaylistEntry>>{};

  /// A single error every playlist call throws, for the error-mapping tests.
  JellyfinException? playlistError;

  /// The id [createPlaylist] returns (and keys new entries under).
  String createdPlaylistId = 'remote-playlist-1';

  // Recorded calls, in order.
  final List<({String name, List<String> itemIds})> createPlaylistCalls =
      <({String name, List<String> itemIds})>[];
  final List<({String playlistId, List<String> itemIds})> addItemCalls =
      <({String playlistId, List<String> itemIds})>[];
  final List<({String playlistId, List<String> itemIds})> removeItemCalls =
      <({String playlistId, List<String> itemIds})>[];
  final List<String> deletedPlaylistIds = <String>[];

  @override
  Future<List<JellyfinPlaylistDto>> fetchPlaylists(
    JellyfinSession session,
  ) async {
    final JellyfinException? error = playlistError;
    if (error != null) throw error;
    return playlists;
  }

  @override
  Future<List<JellyfinPlaylistEntry>> fetchPlaylistEntries(
    JellyfinSession session,
    String playlistId,
  ) async {
    final JellyfinException? error = playlistError;
    if (error != null) throw error;
    return playlistEntries[playlistId] ?? const <JellyfinPlaylistEntry>[];
  }

  @override
  Future<String> createPlaylist(
    JellyfinSession session, {
    required String name,
    List<String> itemIds = const <String>[],
  }) async {
    final JellyfinException? error = playlistError;
    if (error != null) throw error;
    createPlaylistCalls.add((name: name, itemIds: itemIds));
    final String id = createdPlaylistId;
    playlistEntries[id] = <JellyfinPlaylistEntry>[
      for (final String itemId in itemIds)
        JellyfinPlaylistEntry(itemId: itemId, playlistItemId: 'entry-$itemId'),
    ];
    playlists = <JellyfinPlaylistDto>[
      ...playlists,
      JellyfinPlaylistDto(id: id, name: name),
    ];
    return id;
  }

  @override
  Future<void> addItemsToPlaylist(
    JellyfinSession session,
    String playlistId,
    List<String> itemIds,
  ) async {
    final JellyfinException? error = playlistError;
    if (error != null) throw error;
    addItemCalls.add((playlistId: playlistId, itemIds: itemIds));
    final List<JellyfinPlaylistEntry> entries =
        playlistEntries[playlistId] ?? <JellyfinPlaylistEntry>[];
    playlistEntries[playlistId] = <JellyfinPlaylistEntry>[
      ...entries,
      for (final String itemId in itemIds)
        JellyfinPlaylistEntry(itemId: itemId, playlistItemId: 'entry-$itemId'),
    ];
  }

  @override
  Future<void> removeItemsFromPlaylist(
    JellyfinSession session,
    String playlistId,
    List<String> itemIds,
  ) async {
    final JellyfinException? error = playlistError;
    if (error != null) throw error;
    removeItemCalls.add((playlistId: playlistId, itemIds: itemIds));
    final List<JellyfinPlaylistEntry> entries =
        playlistEntries[playlistId] ?? const <JellyfinPlaylistEntry>[];
    final Set<String> targets = itemIds.toSet();
    playlistEntries[playlistId] = <JellyfinPlaylistEntry>[
      for (final JellyfinPlaylistEntry entry in entries)
        if (!targets.contains(entry.itemId)) entry,
    ];
  }

  @override
  Future<void> deletePlaylist(
    JellyfinSession session,
    String playlistId,
  ) async {
    final JellyfinException? error = playlistError;
    if (error != null) throw error;
    deletedPlaylistIds.add(playlistId);
    playlistEntries.remove(playlistId);
    playlists = <JellyfinPlaylistDto>[
      for (final JellyfinPlaylistDto p in playlists)
        if (p.id != playlistId) p,
    ];
  }

  @override
  Future<JellyfinServerInfo> fetchServerInfo(String baseUrl) async {
    lastBaseUrl = baseUrl;
    final JellyfinException? error = serverInfoError;
    if (error != null) {
      throw error;
    }
    return serverInfo ??
        const JellyfinServerInfo(serverName: 'Test Server', version: '10.9.0');
  }

  @override
  Future<JellyfinAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    lastBaseUrl = baseUrl;
    lastUsername = username;
    lastPassword = password;
    lastDeviceId = deviceId;
    final JellyfinException? error = authError;
    if (error != null) {
      throw error;
    }
    return authResult ??
        JellyfinAuthResult(
          accessToken: 'fake-token',
          userId: 'user-1',
          userName: username,
          serverId: 'server-1',
        );
  }

  @override
  Future<List<JellyfinItemDto>> fetchItems(
    JellyfinSession session, {
    required JellyfinItemKind kind,
  }) async {
    requestedKinds.add(kind);
    final JellyfinException? error = itemsError;
    if (error != null) {
      throw error;
    }
    return itemsByKind[kind] ?? const <JellyfinItemDto>[];
  }

  @override
  Future<void> verifySession(JellyfinSession session) async {
    verifyCount++;
    final JellyfinException? error = verifyError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<JellyfinStreamProbe> probeStream(Uri url) async {
    lastProbedUrl = url;
    final JellyfinException? error = probeError;
    if (error != null) {
      throw error;
    }
    return streamProbe ??
        const JellyfinStreamProbe(statusCode: 200, contentType: 'audio/mpeg');
  }

  @override
  Future<Lyrics?> fetchLyrics(JellyfinSession session, String itemId) async {
    lastLyricsItemId = itemId;
    final JellyfinException? error = lyricsError;
    if (error != null) {
      throw error;
    }
    return lyrics;
  }

  @override
  Future<Set<String>> fetchFavoriteIds(JellyfinSession session) async {
    final JellyfinException? error = favoritesError;
    if (error != null) {
      throw error;
    }
    return favoriteIds;
  }

  @override
  Future<void> setFavorite(
    JellyfinSession session,
    String itemId, {
    required bool favorite,
  }) async {
    final JellyfinException? error = favoritesError;
    if (error != null) {
      throw error;
    }
    favoriteCalls.add((itemId: itemId, favorite: favorite));
    if (favorite) {
      favoriteIds = <String>{...favoriteIds, itemId};
    } else {
      favoriteIds = <String>{...favoriteIds}..remove(itemId);
    }
  }
}
