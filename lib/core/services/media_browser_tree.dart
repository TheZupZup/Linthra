import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../catalog/library_grouping.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/playback_state.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../repositories/download_repository.dart';
import '../repositories/favorites_repository.dart';
import '../repositories/music_library_repository.dart';
import '../repositories/playlist_repository.dart';

/// Stable media IDs for the browsable tree exposed to Android Auto and other
/// media browsers.
///
/// Category IDs are plain constants; leaf and container IDs encode where the
/// item lives so a later `playFromMediaId` can be resolved back to a track
/// without extra state:
///  - `library/<uriHash>` — a catalog track (the Songs list), keyed by an
///    opaque hash of the track uri so two providers' same-id songs never collide.
///  - `album/<albumId>` — an album *container* (browsable); its children are
///    `album/<albumId>/<index>` track leaves.
///  - `artist/<artistId>` — an artist *container* (browsable); its children are
///    `artist/<artistId>/<index>` track leaves.
///  - `playlist/<playlistId>` — a playlist *container* (browsable); its children
///    are `playlist/<playlistId>/<index>` track leaves.
///  - `queue/<index>` — a position in the live play queue.
///  - `favorite/<index>` — a position in the (catalog-ordered) favourites list.
///  - `offline/<index>` — a position in the (catalog-ordered) downloaded list.
///
/// The namespaces never collide: a bare category word (`albums`) never starts
/// with the matching container prefix (`album/`), a container `album/<id>` has
/// no trailing `/<index>`, and an album/artist id is a URL-safe base64url token
/// (or an `al-`/`ar-`/`unknown-...` sentinel) that never itself contains a `/`.
///
/// Security invariant: every id is built only from non-secret, opaque ids — a
/// derived album/artist grouping id, a local playlist id, a small integer index,
/// or an opaque hash of the track uri (the Songs leaf). No id ever carries a
/// `jellyfin:`/`subsonic:` uri, a local file path, a Jellyfin/Subsonic access
/// token, or an authenticated stream URL; the stream URL is minted lazily at play
/// time by the resolver, never here.
abstract final class MediaId {
  /// The root the platform requests first (audio_service's `browsableRootId`).
  static const String root = 'root';

  /// The flat "Songs" list (every catalog track). Kept as `library` for id
  /// stability; its displayed title is "Songs".
  static const String library = 'library';
  static const String albums = 'albums';
  static const String artists = 'artists';
  static const String queue = 'queue';
  static const String playlists = 'playlists';
  static const String favorites = 'favorites';
  static const String offline = 'offline';

  /// A non-playable placeholder shown when a section has no content yet (e.g.
  /// "No albums yet"). Browsing into it yields nothing and it never resolves to
  /// a playable track, so an empty section is a friendly dead-stop, not a crash.
  static const String empty = 'empty';

  static const String _libraryPrefix = 'library/';
  static const String _albumPrefix = 'album/';
  static const String _artistPrefix = 'artist/';
  static const String _queuePrefix = 'queue/';
  static const String _playlistPrefix = 'playlist/';
  static const String _favoritePrefix = 'favorite/';
  static const String _offlinePrefix = 'offline/';

  /// A playable leaf for a flat-"Songs" track, keyed by an opaque hash of the
  /// track's provider-namespaced [Track.uri]. Hashing (not the raw uri) keeps the
  /// id collision-free across providers — two songs that share a bare server-side
  /// id (`jellyfin:101` vs `subsonic:101`) get distinct leaves — while upholding
  /// the security invariant above: the id carries no scheme, path, or uri, only
  /// hex. It is also stable for a given track (same uri → same hash), so a
  /// `playFromMediaId` resolves deterministically. Resolve by re-hashing each
  /// candidate's uri and matching against [libraryTrackId].
  static String libraryTrack(String trackUri) =>
      '$_libraryPrefix${libraryTrackHash(trackUri)}';

  /// The opaque, collision-free, leak-safe hash of [trackUri] used as the Songs
  /// leaf id. SHA-256 hex; carries no scheme/path/token.
  static String libraryTrackHash(String trackUri) =>
      sha256.convert(utf8.encode(trackUri)).toString();

  static String queueItem(int index) => '$_queuePrefix$index';

  /// An album *container* node id (its children are the album's tracks).
  static String album(String albumId) => '$_albumPrefix$albumId';

  /// A playable leaf for the track at [index] within album [albumId].
  static String albumTrack(String albumId, int index) =>
      '$_albumPrefix$albumId/$index';

  /// An artist *container* node id (its children are the artist's tracks).
  static String artist(String artistId) => '$_artistPrefix$artistId';

  /// A playable leaf for the track at [index] within artist [artistId].
  static String artistTrack(String artistId, int index) =>
      '$_artistPrefix$artistId/$index';

  /// A playlist *container* node id (its children are the playlist's tracks).
  static String playlist(String playlistId) => '$_playlistPrefix$playlistId';

  /// A playable leaf for the track at [index] within playlist [playlistId].
  static String playlistTrack(String playlistId, int index) =>
      '$_playlistPrefix$playlistId/$index';

  static String favoriteItem(int index) => '$_favoritePrefix$index';
  static String offlineItem(int index) => '$_offlinePrefix$index';

  static bool isLibraryTrack(String id) => id.startsWith(_libraryPrefix);
  static bool isQueueItem(String id) => id.startsWith(_queuePrefix);
  static bool isFavoriteItem(String id) => id.startsWith(_favoritePrefix);
  static bool isOfflineItem(String id) => id.startsWith(_offlinePrefix);

  /// An album/artist/playlist *container*: `<prefix>/<id>` with no further
  /// `/<index>`.
  static bool isAlbumCategory(String id) => _isContainer(id, _albumPrefix);
  static bool isArtistCategory(String id) => _isContainer(id, _artistPrefix);
  static bool isPlaylistCategory(String id) =>
      _isContainer(id, _playlistPrefix);

  /// An album/artist/playlist *track* leaf: `<prefix>/<id>/<index>`.
  static bool isAlbumTrack(String id) => _isLeaf(id, _albumPrefix);
  static bool isArtistTrack(String id) => _isLeaf(id, _artistPrefix);
  static bool isPlaylistTrack(String id) => _isLeaf(id, _playlistPrefix);

  /// The opaque track hash encoded in a library leaf id (`library/<hash>`),
  /// matched against [libraryTrackHash] of a candidate's uri to resolve it.
  static String libraryTrackId(String id) =>
      id.substring(_libraryPrefix.length);

  static String albumCategoryId(String id) => id.substring(_albumPrefix.length);
  static String artistCategoryId(String id) =>
      id.substring(_artistPrefix.length);
  static String playlistCategoryId(String id) =>
      id.substring(_playlistPrefix.length);

  /// The container id encoded in a track leaf `<prefix>/<id>/<index>`. Parsed
  /// from the right so an id that somehow contains a `/` (it shouldn't) is still
  /// handled safely.
  static String albumTrackAlbumId(String id) => _containerId(id, _albumPrefix);
  static String artistTrackArtistId(String id) =>
      _containerId(id, _artistPrefix);
  static String playlistTrackPlaylistId(String id) =>
      _containerId(id, _playlistPrefix);

  /// The position encoded in a track leaf, or -1 when it isn't a valid number.
  static int albumTrackIndex(String id) => _leafIndex(id, _albumPrefix);
  static int artistTrackIndex(String id) => _leafIndex(id, _artistPrefix);
  static int playlistTrackIndex(String id) => _leafIndex(id, _playlistPrefix);

  /// The queue position encoded in [id], or -1 when it isn't a valid number.
  static int queueIndex(String id) =>
      int.tryParse(id.substring(_queuePrefix.length)) ?? -1;

  /// The favourites position encoded in [id], or -1 when it isn't a number.
  static int favoriteIndex(String id) =>
      int.tryParse(id.substring(_favoritePrefix.length)) ?? -1;

  /// The downloads position encoded in [id], or -1 when it isn't a number.
  static int offlineIndex(String id) =>
      int.tryParse(id.substring(_offlinePrefix.length)) ?? -1;

  static bool _isContainer(String id, String prefix) =>
      id.startsWith(prefix) && !id.substring(prefix.length).contains('/');

  static bool _isLeaf(String id, String prefix) =>
      id.startsWith(prefix) && id.substring(prefix.length).contains('/');

  static String _containerId(String id, String prefix) {
    final String rest = id.substring(prefix.length);
    final int slash = rest.lastIndexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }

  static int _leafIndex(String id, String prefix) {
    final String rest = id.substring(prefix.length);
    final int slash = rest.lastIndexOf('/');
    if (slash < 0) return -1;
    return int.tryParse(rest.substring(slash + 1)) ?? -1;
  }
}

/// One node in the browsable media tree, kept free of any `audio_service` type.
///
/// Browsable nodes (categories/containers) have [playable] `false`; track leaves
/// have it `true` and carry their [track] so the handler can build a rich media
/// item (artist, album, duration, artwork) without re-reading the catalog.
@immutable
class MediaNode {
  const MediaNode({
    required this.id,
    required this.title,
    this.subtitle,
    this.playable = false,
    this.track,
    this.artworkUri,
  });

  final String id;
  final String title;
  final String? subtitle;
  final bool playable;
  final Track? track;

  /// Cover art for a *browsable* node (an album/artist container). Track leaves
  /// carry their art on [track] instead. Always a token-free image URL (the same
  /// `Track.artworkUri` source) or null — never a credentialed endpoint.
  final Uri? artworkUri;
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
/// [PlaylistRepository], [FavoritesRepository], and [DownloadRepository], and
/// resolves a selected media ID back to a playback request.
///
/// Pure application logic with no audio backend and no UI dependency: it reads
/// only repository seams (and the pure album/artist grouping in
/// `core/catalog`), so Android Auto can browse it the moment the media service
/// starts — before any phone screen is opened. The handler maps its [MediaNode]s
/// onto `audio_service` media items and drives playback through the
/// [PlaybackController]. That keeps this fully testable with fake repositories.
///
/// Albums and artists are *derived* from the track catalog (the catalog has no
/// persisted album/artist ids), via the same grouping the in-app Library uses,
/// so the car and the phone show identical groupings. Browsing reads only the
/// local synced catalog — it never calls a remote server or mints a stream URL.
///
/// Defensive by design: every repository read is guarded, and an unknown or
/// stale id yields an empty list / null rather than throwing, so a browse or
/// selection request can never crash the media service.
class MediaBrowserTree {
  const MediaBrowserTree(
    this._library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
  })  : _playlists = playlists,
        _favorites = favorites,
        _downloads = downloads;

  final MusicLibraryRepository _library;

  /// User playlists, or null when not wired (tests, or a build without the
  /// playlist feature). When null, no Playlists node is offered.
  final PlaylistRepository? _playlists;

  /// User favourites, or null when not wired. When null, no Favorites node is
  /// offered.
  final FavoritesRepository? _favorites;

  /// Offline downloads, or null when not wired. When null, no Offline node is
  /// offered.
  final DownloadRepository? _downloads;

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
        return _songNodes();
      case MediaId.albums:
        return _albumCategoryNodes();
      case MediaId.artists:
        return _artistCategoryNodes();
      case MediaId.queue:
        return _queueNodes(playback);
      case MediaId.playlists:
        return _playlistCategoryNodes();
      case MediaId.favorites:
        return _favoriteNodes();
      case MediaId.offline:
        return _offlineNodes();
      case MediaId.empty:
        return const <MediaNode>[];
    }
    if (MediaId.isAlbumCategory(parentId)) {
      return _albumTrackNodes(MediaId.albumCategoryId(parentId));
    }
    if (MediaId.isArtistCategory(parentId)) {
      return _artistTrackNodes(MediaId.artistCategoryId(parentId));
    }
    if (MediaId.isPlaylistCategory(parentId)) {
      return _playlistTrackNodes(MediaId.playlistCategoryId(parentId));
    }
    return const <MediaNode>[];
  }

  /// Resolves a selected leaf [mediaId] to what should play, or null when it
  /// doesn't name a playable track (e.g. a stale id, or a category/container).
  Future<MediaPlaybackRequest?> resolve(
    String mediaId,
    PlaybackState playback,
  ) async {
    if (MediaId.isLibraryTrack(mediaId)) {
      final List<Track> tracks = await _allTracks();
      // Match by the uri hash, so two providers' same-id songs resolve to the
      // right copy (the flat Songs list can now hold both).
      final String trackHash = MediaId.libraryTrackId(mediaId);
      final int index = tracks.indexWhere(
          (Track t) => MediaId.libraryTrackHash(t.uri) == trackHash);
      if (index < 0) return null;
      return MediaPlaybackRequest(tracks: tracks, startIndex: index);
    }
    if (MediaId.isAlbumTrack(mediaId)) {
      final List<Track> tracks = tracksForAlbum(
          await _allTracks(), MediaId.albumTrackAlbumId(mediaId));
      return _requestAt(tracks, MediaId.albumTrackIndex(mediaId));
    }
    if (MediaId.isArtistTrack(mediaId)) {
      final List<Track> tracks = tracksForArtist(
          await _allTracks(), MediaId.artistTrackArtistId(mediaId));
      return _requestAt(tracks, MediaId.artistTrackIndex(mediaId));
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
      return _requestAt(
          await _favoriteTracks(), MediaId.favoriteIndex(mediaId));
    }
    if (MediaId.isOfflineItem(mediaId)) {
      return _requestAt(await _offlineTracks(), MediaId.offlineIndex(mediaId));
    }
    return null;
  }

  /// A request that starts [tracks] at [index], or null when the index is out of
  /// range (a stale leaf id whose list has since shrunk).
  MediaPlaybackRequest? _requestAt(List<Track> tracks, int index) {
    if (index < 0 || index >= tracks.length) return null;
    return MediaPlaybackRequest(tracks: tracks, startIndex: index);
  }

  /// The top-level categories. Songs / Albums / Artists (the library) and Queue
  /// are always present; Playlists, Favorites, and Offline appear only when the
  /// user actually has some, so the car never shows an empty user-data category.
  /// Always non-empty.
  Future<List<MediaNode>> _rootNodes() async {
    return <MediaNode>[
      const MediaNode(id: MediaId.library, title: 'Songs'),
      const MediaNode(id: MediaId.albums, title: 'Albums'),
      const MediaNode(id: MediaId.artists, title: 'Artists'),
      if (await _hasPlaylists())
        const MediaNode(id: MediaId.playlists, title: 'Playlists'),
      if (await _hasFavorites())
        const MediaNode(id: MediaId.favorites, title: 'Favorites'),
      if (await _hasOffline())
        const MediaNode(id: MediaId.offline, title: 'Offline'),
      const MediaNode(id: MediaId.queue, title: 'Queue'),
    ];
  }

  Future<bool> _hasPlaylists() async => (await _allPlaylists()).isNotEmpty;

  Future<bool> _hasFavorites() async => (await _favoriteIds()).isNotEmpty;

  Future<bool> _hasOffline() async => (await _downloadedIds()).isNotEmpty;

  Future<List<MediaNode>> _songNodes() async {
    final List<Track> tracks = await _allTracks();
    if (tracks.isEmpty) return _placeholder('Sync your library first');
    return <MediaNode>[
      for (final Track track in tracks)
        // Key the leaf by a hash of the provider-namespaced uri so two same-id
        // songs from different providers get distinct, collision-free media ids.
        _trackNode(MediaId.libraryTrack(track.uri), track),
    ];
  }

  Future<List<MediaNode>> _albumCategoryNodes() async {
    final List<Album> albums = groupAlbums(await _allTracks());
    if (albums.isEmpty) return _placeholder('No albums yet');
    return <MediaNode>[
      for (final Album album in albums)
        MediaNode(
          id: MediaId.album(album.id),
          title: album.title,
          subtitle: album.artistName,
          artworkUri: album.artworkUri,
        ),
    ];
  }

  Future<List<MediaNode>> _albumTrackNodes(String albumId) async {
    final List<Track> tracks = tracksForAlbum(await _allTracks(), albumId);
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.albumTrack(albumId, i), tracks[i]),
    ];
  }

  Future<List<MediaNode>> _artistCategoryNodes() async {
    final List<Artist> artists = groupArtists(await _allTracks());
    if (artists.isEmpty) return _placeholder('No artists yet');
    return <MediaNode>[
      for (final Artist artist in artists)
        MediaNode(
          id: MediaId.artist(artist.id),
          title: artist.name,
          subtitle: _artistSubtitle(artist),
          artworkUri: artist.artworkUri,
        ),
    ];
  }

  Future<List<MediaNode>> _artistTrackNodes(String artistId) async {
    final List<Track> tracks = tracksForArtist(await _allTracks(), artistId);
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.artistTrack(artistId, i), tracks[i]),
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
    if (playlists.isEmpty) return _placeholder('No playlists yet');
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
    if (tracks.isEmpty) return _placeholder('No favorites yet');
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.favoriteItem(i), tracks[i]),
    ];
  }

  Future<List<MediaNode>> _offlineNodes() async {
    final List<Track> tracks = await _offlineTracks();
    if (tracks.isEmpty) return _placeholder('No offline tracks yet');
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.offlineItem(i), tracks[i]),
    ];
  }

  /// A single non-playable placeholder row carrying a friendly, secret-free
  /// [message], so an empty section explains itself instead of showing a blank
  /// car screen. Browsing into it (id [MediaId.empty]) yields nothing.
  List<MediaNode> _placeholder(String message) =>
      <MediaNode>[MediaNode(id: MediaId.empty, title: message)];

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

  /// The downloaded (offline) tracks in stable catalog order, so an
  /// `offline/<index>` leaf listed and resolved in the same browse session
  /// refers to the same track. Only user-downloaded tracks appear — smart
  /// pre-cached tracks are deliberately not reported as downloaded by the
  /// repository, so they never leak into this section. Ids with no catalog track
  /// are dropped.
  Future<List<Track>> _offlineTracks() async {
    final Set<String> ids = await _downloadedIds();
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

  /// The current downloaded track-id set. Guarded: any failure yields an empty
  /// set so a misbehaving download backend can't break browsing.
  Future<Set<String>> _downloadedIds() async {
    final DownloadRepository? downloads = _downloads;
    if (downloads == null) return const <String>{};
    try {
      return (await downloads.downloadedTrackIds()).toSet();
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
    final String label = track.artistAlbumLabel;
    return label.isEmpty ? null : label;
  }

  /// A track count for a playlist container row, e.g. "1 track" / "12 tracks".
  static String _playlistSubtitle(Playlist playlist) {
    final int n = playlist.length;
    return n == 1 ? '1 track' : '$n tracks';
  }

  /// "N albums • M songs" (or just the song count), like the in-app artist
  /// header, so an artist row reads at a glance.
  static String _artistSubtitle(Artist artist) {
    final String songs =
        artist.trackCount == 1 ? '1 song' : '${artist.trackCount} songs';
    if (artist.albumCount <= 0) return songs;
    final String albums =
        artist.albumCount == 1 ? '1 album' : '${artist.albumCount} albums';
    return '$albums • $songs';
  }
}
