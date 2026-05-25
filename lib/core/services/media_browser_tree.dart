import 'package:flutter/foundation.dart';

import '../models/playback_state.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../repositories/favorites_repository.dart';
import '../repositories/music_library_repository.dart';
import '../repositories/playlist_repository.dart';

/// Stable media IDs for the browsable tree exposed to Android Auto and other
/// media browsers.
///
/// Category IDs are plain constants; leaf IDs encode where the item lives so a
/// later `playFromMediaId` can be resolved back to a track without extra state:
///  - `library/<trackId>` — a catalog track.
///  - `queue/<index>` — a position in the live play queue.
///  - `playlist/<playlistId>` — a playlist *category* (browsable).
///  - `playlist/<playlistId>/<index>` — a position within that playlist.
///  - `favorite/<index>` — a position in the (catalog-ordered) favourites list.
///
/// The namespaces never collide (`library` vs. `library/...`; a playlist
/// category `playlist/<id>` has no trailing `/<index>`, a playlist track does).
///
/// Security invariant: every id is built only from non-secret, opaque ids — a
/// catalog/track id (e.g. the `jellyfin:` scheme is *not* used here; the bare
/// item id is), a local playlist id, or a small integer index. No id ever
/// carries a Jellyfin/Subsonic access token or an authenticated stream URL; the
/// stream URL is minted lazily at play time by the resolver, never here.
abstract final class MediaId {
  /// The root the platform requests first (audio_service's `browsableRootId`).
  static const String root = 'root';
  static const String library = 'library';
  static const String queue = 'queue';
  static const String playlists = 'playlists';
  static const String favorites = 'favorites';

  static const String _libraryPrefix = 'library/';
  static const String _queuePrefix = 'queue/';
  static const String _playlistPrefix = 'playlist/';
  static const String _favoritePrefix = 'favorite/';

  static String libraryTrack(String trackId) => '$_libraryPrefix$trackId';
  static String queueItem(int index) => '$_queuePrefix$index';

  /// A playlist *category* node id (its children are the playlist's tracks).
  static String playlist(String playlistId) => '$_playlistPrefix$playlistId';

  /// A playable leaf for the track at [index] within playlist [playlistId].
  static String playlistTrack(String playlistId, int index) =>
      '$_playlistPrefix$playlistId/$index';

  static String favoriteItem(int index) => '$_favoritePrefix$index';

  static bool isLibraryTrack(String id) => id.startsWith(_libraryPrefix);
  static bool isQueueItem(String id) => id.startsWith(_queuePrefix);
  static bool isFavoriteItem(String id) => id.startsWith(_favoritePrefix);

  /// A playlist *category* node: `playlist/<id>` with no further `/<index>`.
  static bool isPlaylistCategory(String id) =>
      id.startsWith(_playlistPrefix) &&
      !id.substring(_playlistPrefix.length).contains('/');

  /// A playlist *track* leaf: `playlist/<id>/<index>`.
  static bool isPlaylistTrack(String id) =>
      id.startsWith(_playlistPrefix) &&
      id.substring(_playlistPrefix.length).contains('/');

  static String libraryTrackId(String id) =>
      id.substring(_libraryPrefix.length);

  static String playlistCategoryId(String id) =>
      id.substring(_playlistPrefix.length);

  /// The playlist id encoded in a playlist-track leaf `playlist/<id>/<index>`.
  /// Parsed from the right so an id containing a `/` (it shouldn't) is still
  /// handled safely.
  static String playlistTrackPlaylistId(String id) {
    final String rest = id.substring(_playlistPrefix.length);
    final int slash = rest.lastIndexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }

  /// The position encoded in a playlist-track leaf, or -1 when it isn't a valid
  /// number.
  static int playlistTrackIndex(String id) {
    final String rest = id.substring(_playlistPrefix.length);
    final int slash = rest.lastIndexOf('/');
    if (slash < 0) return -1;
    return int.tryParse(rest.substring(slash + 1)) ?? -1;
  }

  /// The queue position encoded in [id], or -1 when it isn't a valid number.
  static int queueIndex(String id) =>
      int.tryParse(id.substring(_queuePrefix.length)) ?? -1;

  /// The favourites position encoded in [id], or -1 when it isn't a number.
  static int favoriteIndex(String id) =>
      int.tryParse(id.substring(_favoritePrefix.length)) ?? -1;
}

/// One node in the browsable media tree, kept free of any `audio_service` type.
///
/// Browsable nodes (categories) have [playable] `false`; track leaves have it
/// `true` and carry their [track] so the handler can build a rich media item
/// (artist, album, duration, artwork) without re-reading the catalog.
@immutable
class MediaNode {
  const MediaNode({
    required this.id,
    required this.title,
    this.subtitle,
    this.playable = false,
    this.track,
  });

  final String id;
  final String title;
  final String? subtitle;
  final bool playable;
  final Track? track;
}

/// What to play when a browsable item is selected: the [tracks] to load and the
/// [startIndex] within them to begin at. Mirrors [PlaybackController.playTracks]
/// so the rest of the queue becomes up-next, exactly like tapping a track in the
/// in-app library.
@immutable
class MediaPlaybackRequest {
  const MediaPlaybackRequest({required this.tracks, required this.startIndex});

  final List<Track> tracks;
  final int startIndex;
}

/// Builds the browsable media tree from the [MusicLibraryRepository] (catalog),
/// a [PlaybackState] snapshot (the live queue), and — when wired — the user's
/// [PlaylistRepository] and [FavoritesRepository], and resolves a selected media
/// ID back to a playback request.
///
/// Pure application logic with no audio backend and no UI dependency: it reads
/// only repository seams, so Android Auto can browse it the moment the media
/// service starts — before any phone screen is opened. The handler maps its
/// [MediaNode]s onto `audio_service` media items and drives playback through the
/// [PlaybackController]. That keeps this fully testable with fake repositories.
///
/// Defensive by design: every repository read is guarded, and an unknown or
/// stale id yields an empty list / null rather than throwing, so a browse or
/// selection request can never crash the media service.
class MediaBrowserTree {
  const MediaBrowserTree(
    this._library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
  })  : _playlists = playlists,
        _favorites = favorites;

  final MusicLibraryRepository _library;

  /// User playlists, or null when not wired (tests, or a build without the
  /// playlist feature). When null, no Playlists node is offered.
  final PlaylistRepository? _playlists;

  /// User favourites, or null when not wired. When null, no Favorites node is
  /// offered.
  final FavoritesRepository? _favorites;

  /// The children of [parentId], for the given live [playback] snapshot.
  /// Unknown parents yield an empty list rather than throwing, so an unexpected
  /// browse request can never crash the media service.
  Future<List<MediaNode>> childrenOf(
    String parentId,
    PlaybackState playback,
  ) async {
    switch (parentId) {
      case MediaId.root:
        return _rootNodes();
      case MediaId.library:
        return _libraryNodes();
      case MediaId.queue:
        return _queueNodes(playback);
      case MediaId.playlists:
        return _playlistCategoryNodes();
      case MediaId.favorites:
        return _favoriteNodes();
    }
    if (MediaId.isPlaylistCategory(parentId)) {
      return _playlistTrackNodes(MediaId.playlistCategoryId(parentId));
    }
    return const <MediaNode>[];
  }

  /// Resolves a selected leaf [mediaId] to what should play, or null when it
  /// doesn't name a playable track (e.g. a stale id, or a category).
  Future<MediaPlaybackRequest?> resolve(
    String mediaId,
    PlaybackState playback,
  ) async {
    if (MediaId.isLibraryTrack(mediaId)) {
      final List<Track> tracks = await _allTracks();
      final String trackId = MediaId.libraryTrackId(mediaId);
      final int index = tracks.indexWhere((Track t) => t.id == trackId);
      if (index < 0) return null;
      return MediaPlaybackRequest(tracks: tracks, startIndex: index);
    }
    if (MediaId.isQueueItem(mediaId)) {
      final List<Track> tracks = _currentQueue(playback);
      return _requestAt(tracks, MediaId.queueIndex(mediaId));
    }
    if (MediaId.isPlaylistTrack(mediaId)) {
      final List<Track> tracks =
          await _playlistTracks(MediaId.playlistTrackPlaylistId(mediaId));
      return _requestAt(tracks, MediaId.playlistTrackIndex(mediaId));
    }
    if (MediaId.isFavoriteItem(mediaId)) {
      final List<Track> tracks = await _favoriteTracks();
      return _requestAt(tracks, MediaId.favoriteIndex(mediaId));
    }
    return null;
  }

  /// A request that starts [tracks] at [index], or null when the index is out of
  /// range (a stale leaf id whose list has since shrunk).
  MediaPlaybackRequest? _requestAt(List<Track> tracks, int index) {
    if (index < 0 || index >= tracks.length) return null;
    return MediaPlaybackRequest(tracks: tracks, startIndex: index);
  }

  /// The top-level categories. Library and Queue are always present; Playlists
  /// and Favorites appear only when the user actually has some, so Android Auto
  /// never shows a dead-end category. Always non-empty.
  Future<List<MediaNode>> _rootNodes() async {
    return <MediaNode>[
      const MediaNode(id: MediaId.library, title: 'Library'),
      const MediaNode(id: MediaId.queue, title: 'Queue'),
      if (await _hasPlaylists())
        const MediaNode(id: MediaId.playlists, title: 'Playlists'),
      if (await _hasFavorites())
        const MediaNode(id: MediaId.favorites, title: 'Favorites'),
    ];
  }

  Future<bool> _hasPlaylists() async => (await _allPlaylists()).isNotEmpty;

  Future<bool> _hasFavorites() async => (await _favoriteIds()).isNotEmpty;

  Future<List<MediaNode>> _libraryNodes() async {
    final List<Track> tracks = await _allTracks();
    return <MediaNode>[
      for (final Track track in tracks)
        _trackNode(MediaId.libraryTrack(track.id), track),
    ];
  }

  List<MediaNode> _queueNodes(PlaybackState playback) {
    final List<Track> tracks = _currentQueue(playback);
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.queueItem(i), tracks[i]),
    ];
  }

  Future<List<MediaNode>> _playlistCategoryNodes() async {
    final List<Playlist> playlists = await _allPlaylists();
    return <MediaNode>[
      for (final Playlist playlist in playlists)
        MediaNode(
          id: MediaId.playlist(playlist.id),
          title: playlist.name,
          subtitle: _playlistSubtitle(playlist),
        ),
    ];
  }

  Future<List<MediaNode>> _playlistTrackNodes(String playlistId) async {
    final List<Track> tracks = await _playlistTracks(playlistId);
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.playlistTrack(playlistId, i), tracks[i]),
    ];
  }

  Future<List<MediaNode>> _favoriteNodes() async {
    final List<Track> tracks = await _favoriteTracks();
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.favoriteItem(i), tracks[i]),
    ];
  }

  /// The full live queue as a flat list: the current track followed by up-next,
  /// matching the `queue/<index>` ids the queue nodes are built with.
  List<Track> _currentQueue(PlaybackState playback) {
    final Track? current = playback.currentTrack;
    return <Track>[if (current != null) current, ...playback.upNext];
  }

  /// The favourite tracks in stable catalog order, so a `favorite/<index>` leaf
  /// listed and resolved within the same browse session refers to the same
  /// track. Favourite ids with no matching catalog track (e.g. a server
  /// favourite not synced to this device) are dropped — they can't be played.
  Future<List<Track>> _favoriteTracks() async {
    final Set<String> ids = await _favoriteIds();
    if (ids.isEmpty) return const <Track>[];
    final List<Track> tracks = await _allTracks();
    return <Track>[
      for (final Track track in tracks)
        if (ids.contains(track.id)) track,
    ];
  }

  /// The tracks of playlist [playlistId] in playlist order, resolved against the
  /// catalog. Ids with no catalog track are dropped (can't be played).
  Future<List<Track>> _playlistTracks(String playlistId) async {
    final PlaylistRepository? playlists = _playlists;
    if (playlists == null) return const <Track>[];
    final Playlist? playlist = await _playlistById(playlists, playlistId);
    if (playlist == null || playlist.trackIds.isEmpty) return const <Track>[];
    final Map<String, Track> byId = <String, Track>{
      for (final Track track in await _allTracks()) track.id: track,
    };
    return <Track>[
      for (final String id in playlist.trackIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Looks up a playlist by id, guarded so a repository error yields null
  /// rather than throwing out of a browse/resolve.
  Future<Playlist?> _playlistById(
    PlaylistRepository playlists,
    String id,
  ) async {
    try {
      return await playlists.getPlaylistById(id);
    } catch (_) {
      return null;
    }
  }

  /// The current favourite track-id set, read from the repository's stream
  /// (which yields the current set immediately). Guarded: any failure yields an
  /// empty set so a misbehaving favourites backend can't break browsing.
  Future<Set<String>> _favoriteIds() async {
    final FavoritesRepository? favorites = _favorites;
    if (favorites == null) return const <String>{};
    try {
      return await favorites.favoritesStream.first;
    } catch (_) {
      return const <String>{};
    }
  }

  Future<List<Playlist>> _allPlaylists() async {
    final PlaylistRepository? playlists = _playlists;
    if (playlists == null) return const <Playlist>[];
    try {
      return await playlists.getAllPlaylists();
    } catch (_) {
      return const <Playlist>[];
    }
  }

  /// All catalog tracks, guarded so a catalog read error yields an empty list
  /// rather than throwing out of a browse/resolve.
  Future<List<Track>> _allTracks() async {
    try {
      return await _library.getAllTracks();
    } catch (_) {
      return const <Track>[];
    }
  }

  MediaNode _trackNode(String id, Track track) {
    return MediaNode(
      id: id,
      title: track.title,
      subtitle: _subtitle(track),
      playable: true,
      track: track,
    );
  }

  /// "Artist • Album", dropping whichever parts are missing.
  static String? _subtitle(Track track) {
    final List<String> parts = <String>[
      if (track.artistName != null && track.artistName!.isNotEmpty)
        track.artistName!,
      if (track.albumName != null && track.albumName!.isNotEmpty)
        track.albumName!,
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }

  /// A track count for a playlist category row, e.g. "1 track" / "12 tracks".
  static String _playlistSubtitle(Playlist playlist) {
    final int n = playlist.length;
    return n == 1 ? '1 track' : '$n tracks';
  }
}
