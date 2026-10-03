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
import '../repositories/download_store.dart';
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
///  - `queue/<index>/<uriHash>`: a position in the live play queue, with the
///    opaque hash of the track listed there (see [MediaId.queueItem]).
///  - `favorite/<index>` — a position in the (catalog-ordered) favourites list.
///  - `offline/<index>` — a position in the (catalog-ordered) downloaded list.
///  - `page/<sectionId>/<start>-<end>` — a *browse page* container: the
///    half-open window `[start, end)` of some other section's children. Always
///    browsable, never playable (see [MediaBrowserTree] for why big sections are
///    served as pages).
///
/// The album, artist, playlist, favourite and offline leaves are published to
/// the media browser as `<leaf id>@<uriHash>`, with the track they list (see
/// [MediaId.listing]).
///
/// The namespaces never collide: a bare category word (`albums`) never starts
/// with the matching container prefix (`album/`), a container `album/<id>` has
/// no trailing `/<index>`, and an album/artist id is a URL-safe base64url token
/// (or an `al-`/`ar-`/`unknown-...` sentinel) that never itself contains a `/`.
/// The `page/` prefix is likewise distinct from every playable-leaf prefix, so a
/// page container can never be mistaken for — or resolved as — a track.
///
/// Security invariant: every id is built only from non-secret, opaque ids — a
/// derived album/artist grouping id, a local playlist id, a small integer index,
/// a browse-page window (two integers), or an opaque hash of the track uri (the
/// Songs and Queue leaves, and the `@<uriHash>` of a published leaf). No id
/// ever carries a `jellyfin:`/`subsonic:` uri, a local file path, a
/// Jellyfin/Subsonic access token, or an authenticated stream URL; the stream
/// URL is minted lazily at play time by the resolver, never here.
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
  static const String _pagePrefix = 'page/';

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

  /// A row of the Queue list: [index] counts from the current track (0), and
  /// [trackUri] is the track listed there, carried as its opaque
  /// [libraryTrackHash].
  ///
  /// The position alone goes stale: the car keeps showing the list it was
  /// given (nothing tells it the children changed), while the queue moves on
  /// under it whenever a track ends, Next is pressed, or the phone starts
  /// another queue. With only the position, a row picked after that played
  /// whatever had moved into its place. The hash lets [MediaBrowserTree.resolve]
  /// find the song the row showed, or nothing. A bare `queue/<index>` is still
  /// read, by position.
  static String queueItem(int index, [String? trackUri]) => trackUri == null
      ? '$_queuePrefix$index'
      : '$_queuePrefix$index/${libraryTrackHash(trackUri)}';

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

  /// A *browse page* container: the half-open window `[start, end)` of the
  /// children of [sectionId]. Browsable only — deliberately in its own `page/`
  /// namespace so it can never be confused with (or resolved as) a playable
  /// leaf, and deterministic: the same section at the same size always yields
  /// the same page ids, so repeated browses are byte-identical.
  ///
  /// [sectionId] may itself contain a `/` (e.g. `album/<id>`); the window is
  /// always the last `/`-segment, so parsing back is unambiguous.
  static String browsePage(String sectionId, int start, int end) =>
      '$_pagePrefix$sectionId/$start-$end';

  static bool isBrowsePage(String id) => id.startsWith(_pagePrefix);

  /// The section and window encoded in a `page/...` id, or null when [id] isn't
  /// a well-formed page container. A malformed or hostile id (a negative bound,
  /// an empty section, a nested `page/page/...`) yields null rather than
  /// throwing, so a stale or crafted browse request is a safe dead-stop.
  static BrowsePage? browsePageOf(String id) {
    if (!isBrowsePage(id)) return null;
    final String rest = id.substring(_pagePrefix.length);
    final int slash = rest.lastIndexOf('/');
    if (slash <= 0) return null;
    final String sectionId = rest.substring(0, slash);
    // A page of a page is never generated (sub-pages keep the original section
    // id), so treat one as malformed rather than recursing into it.
    if (sectionId.startsWith(_pagePrefix)) return null;
    final String window = rest.substring(slash + 1);
    final int dash = window.indexOf('-');
    if (dash <= 0) return null;
    final int? start = int.tryParse(window.substring(0, dash));
    final int? end = int.tryParse(window.substring(dash + 1));
    if (start == null || end == null || start < 0 || end <= start) return null;
    return BrowsePage(sectionId: sectionId, start: start, end: end);
  }

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
  static int queueIndex(String id) {
    final String rest = id.substring(_queuePrefix.length);
    final int slash = rest.indexOf('/');
    return int.tryParse(slash < 0 ? rest : rest.substring(0, slash)) ?? -1;
  }

  /// The hash of the track a Queue row was listed for, or null for a bare
  /// `queue/<index>`.
  static String? queueTrackHash(String id) {
    final String rest = id.substring(_queuePrefix.length);
    final int slash = rest.indexOf('/');
    return slash < 0 ? null : rest.substring(slash + 1);
  }

  /// The favourites position encoded in [id], or -1 when it isn't a number.
  static int favoriteIndex(String id) =>
      int.tryParse(id.substring(_favoritePrefix.length)) ?? -1;

  /// The downloads position encoded in [id], or -1 when it isn't a number.
  static int offlineIndex(String id) =>
      int.tryParse(id.substring(_offlinePrefix.length)) ?? -1;

  /// The id a playable row is published under: [id], and for a row that names
  /// its track by position (an album, artist, playlist, favourite or offline
  /// leaf) the opaque [libraryTrackHash] of [trackUri] after an `@`.
  ///
  /// The position alone goes stale: the car keeps showing the list it was
  /// given, and a download finishing, a favourites or library sync landing, or
  /// a playlist edit moves songs to other positions in it. With the hash,
  /// [MediaBrowserTree.resolve] plays the song the row showed, or nothing.
  /// Songs and Queue rows already carry their track and are returned as they
  /// are.
  static String listing(String id, String trackUri) => _namesTrackByPosition(id)
      ? '$id$_listedTrackSeparator${libraryTrackHash(trackUri)}'
      : id;

  /// A published row [id] split back into the id it was made from and the
  /// hash of the track it listed, or [id] itself with no hash when it carries
  /// none (see [listing]).
  static ({String id, String? trackHash}) listedTrackOf(String id) {
    final int separator = id.lastIndexOf(_listedTrackSeparator);
    if (separator < 0) return (id: id, trackHash: null);
    final String plain = id.substring(0, separator);
    final String hash = id.substring(separator + 1);
    if (!_namesTrackByPosition(plain) || !_trackHashShape.hasMatch(hash)) {
      return (id: id, trackHash: null);
    }
    return (id: plain, trackHash: hash);
  }

  static bool _namesTrackByPosition(String id) =>
      isAlbumTrack(id) ||
      isArtistTrack(id) ||
      isPlaylistTrack(id) ||
      isFavoriteItem(id) ||
      isOfflineItem(id);

  static const String _listedTrackSeparator = '@';

  /// What [libraryTrackHash] produces: SHA-256 as lower-case hex.
  static final RegExp _trackHashShape = RegExp(r'^[0-9a-f]{64}$');

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

/// Android's `MediaBrowserCompat` browse options — the page window a media
/// browser client asks for when it subscribes — and how to apply one.
///
/// Applying these is the **app's** job on this stack, and only the app's.
/// `MediaBrowserServiceCompat.performLoadChildren` filters a result through its
/// own `applyOptions` *only* when `RESULT_FLAG_OPTION_NOT_HANDLED` is set, and
/// that flag is set only by the base-class `onLoadChildren(parentId, result,
/// options)` — the compatibility shim for services that don't handle options.
/// `audio_service`'s `AudioService` overrides that three-argument method, so the
/// flag is never set on Linthra's path and the framework passes the returned
/// list through untouched. Applying the window here is therefore correct and
/// carries no double-paging risk: without it a client that asks for page 1 would
/// silently receive page 0's list all over again.
abstract final class MediaBrowseOptions {
  /// `MediaBrowserCompat.EXTRA_PAGE` — the zero-based page index requested.
  static const String extraPage = 'android.media.browse.extra.PAGE';

  /// `MediaBrowserCompat.EXTRA_PAGE_SIZE` — how many children per page.
  static const String extraPageSize = 'android.media.browse.extra.PAGE_SIZE';

  /// [children] narrowed to the page [options] asks for, or all of them when no
  /// (or no usable) page is requested.
  ///
  /// Deliberately a byte-for-byte port of `MediaBrowserServiceCompat`'s own
  /// `applyOptions`, including its edge cases — a page beyond the end and a
  /// nonsensical window both yield an empty list (which is how a client learns
  /// it has reached the end), and a partly-specified window is treated exactly
  /// as the framework would. Matching it means enabling or disabling app-side
  /// paging can never change what a client sees.
  static List<T> applyPage<T>(List<T> children, Map<String, dynamic>? options) {
    if (options == null) return children;
    final int page = _intOf(options[extraPage]);
    final int pageSize = _intOf(options[extraPageSize]);
    if (page == -1 && pageSize == -1) return children;
    final int fromIndex = pageSize * page;
    if (page < 0 || pageSize < 1 || fromIndex >= children.length) {
      return <T>[];
    }
    final int toIndex = fromIndex + pageSize > children.length
        ? children.length
        : fromIndex + pageSize;
    return children.sublist(fromIndex, toIndex);
  }

  /// A bundle value as an int, or -1 ("absent") when it isn't one. The platform
  /// hands these over as Java `Integer`s, but a head unit is free to put
  /// anything in the bundle, so a non-integer is treated as absent rather than
  /// throwing out of a browse.
  static int _intOf(Object? value) => value is int ? value : -1;
}

/// The section and half-open window `[start, end)` a `page/...` container names.
@immutable
class BrowsePage {
  const BrowsePage({
    required this.sectionId,
    required this.start,
    required this.end,
  });

  /// The id of the section being paged (`library`, `albums`, `album/<id>`, …).
  final String sectionId;

  /// First child index in this page (inclusive).
  final int start;

  /// One past the last child index in this page (exclusive).
  final int end;
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
  MediaBrowserTree(
    this._library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    Duration catalogSnapshotTtl = _defaultCatalogSnapshotTtl,
  })  : _playlists = playlists,
        _favorites = favorites,
        _downloads = downloads,
        _catalogSnapshotTtl = catalogSnapshotTtl;

  /// The largest number of children this tree ever returns for one browse
  /// request. Sections bigger than this are served as `page/` containers.
  ///
  /// The bound exists because the whole child list is delivered to the media
  /// browser client in a single Binder transaction, whose per-process buffer is
  /// ~1 MB; a Songs response crosses that at roughly 1.5k tracks, and the
  /// resulting `RemoteException` is swallowed by `MediaBrowserServiceCompat` —
  /// the client simply never receives `onChildrenLoaded` and spins forever. At
  /// this size a page of rich track rows is on the order of 150 kB, comfortably
  /// inside the buffer even alongside other in-flight transactions.
  ///
  /// A client's own `EXTRA_PAGE` window (honoured in `LinthraAudioHandler`, see
  /// [MediaBrowseOptions]) does not replace this bound: a client may subscribe
  /// with no options at all, and on this stack nothing between here and the car
  /// shortens an over-long list on its own. So the tree is bounded first, and a
  /// requested page narrows it further.
  static const int browsePageSize = 250;

  /// How long one catalog read is reused across browse requests.
  ///
  /// Android Auto issues a burst of `getChildren` calls for a single user
  /// action (and `audio_service` re-requests each node once more, because its
  /// default `subscribeToChildren` stream is seeded and immediately triggers a
  /// `notifyChildrenChanged`). Re-reading a 200k-row catalog for each of those
  /// is the second half of the "endless scanning" symptom, and it would also let
  /// the page windows shift mid-scroll if a sync landed between two requests.
  /// One short-lived snapshot makes a browse session cheap *and* internally
  /// consistent, while staying short enough that a freshly synced library shows
  /// up without reconnecting.
  static const Duration _defaultCatalogSnapshotTtl = Duration(seconds: 30);

  final MusicLibraryRepository _library;

  final Duration _catalogSnapshotTtl;

  /// The last catalog read, its timestamp, and the read currently in flight —
  /// see [_defaultCatalogSnapshotTtl]. `_inFlight` collapses the concurrent
  /// browse requests Android Auto issues into a single repository read.
  List<Track>? _catalogSnapshot;
  DateTime? _catalogSnapshotAt;
  Future<List<Track>>? _catalogInFlight;

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
  ///
  /// The result is always at most [browsePageSize] nodes: a section with more
  /// children than that is served as a list of `page/` containers spanning it
  /// (see [_bounded]), so no browse response can ever outgrow the media
  /// browser's Binder transaction — while every child stays reachable by
  /// walking into the page it falls in.
  Future<List<MediaNode>> childrenOf(
    String parentId,
    PlaybackState playback,
  ) async {
    final BrowsePage? page = MediaId.browsePageOf(parentId);
    if (page != null) {
      final _Section section = await _sectionOf(page.sectionId, playback);
      return _bounded(section, page.sectionId, page.start, page.end);
    }
    final _Section section = await _sectionOf(parentId, playback);
    return _bounded(section, parentId, 0, section.length);
  }

  /// The children of [sectionId] as a lazily-indexable list, so paging a huge
  /// section materializes only the window it returns. Unknown sections yield an
  /// empty section rather than throwing.
  Future<_Section> _sectionOf(String sectionId, PlaybackState playback) async {
    switch (sectionId) {
      case MediaId.root:
        return _Section.of(await _rootNodes());
      case MediaId.library:
        return _songSection();
      case MediaId.albums:
        return _Section.of(await _albumCategoryNodes());
      case MediaId.artists:
        return _Section.of(await _artistCategoryNodes());
      case MediaId.queue:
        return _queueSection(playback);
      case MediaId.playlists:
        return _Section.of(await _playlistCategoryNodes());
      case MediaId.favorites:
        return _Section.of(await _favoriteNodes());
      case MediaId.offline:
        return _Section.of(await _offlineNodes());
      case MediaId.empty:
        return _Section.empty;
    }
    if (MediaId.isAlbumCategory(sectionId)) {
      return _Section.of(
          await _albumTrackNodes(MediaId.albumCategoryId(sectionId)));
    }
    if (MediaId.isArtistCategory(sectionId)) {
      return _Section.of(
          await _artistTrackNodes(MediaId.artistCategoryId(sectionId)));
    }
    if (MediaId.isPlaylistCategory(sectionId)) {
      return _Section.of(
          await _playlistTrackNodes(MediaId.playlistCategoryId(sectionId)));
    }
    return _Section.empty;
  }

  /// The window `[start, end)` of [section], bounded to [browsePageSize] nodes.
  ///
  /// A window that already fits is materialized as-is. A larger one is covered
  /// by evenly sized `page/` containers instead — at most [browsePageSize] of
  /// them, by growing the step in powers of [browsePageSize] — so browsing
  /// recurses into narrower windows until it reaches real children. Two levels
  /// already span 62 500 children and three span 15 million, so the tree stays
  /// shallow for any realistic library.
  ///
  /// The split is a pure function of the window and the section's size, so
  /// repeated browses of an unchanged section produce byte-identical page ids.
  /// Out-of-range windows (a stale page id whose section has since shrunk) clamp
  /// to what exists, and an empty one yields no children rather than throwing.
  List<MediaNode> _bounded(
    _Section section,
    String sectionId,
    int windowStart,
    int windowEnd,
  ) {
    final int start = windowStart < 0 ? 0 : windowStart;
    final int end = windowEnd > section.length ? section.length : windowEnd;
    if (end <= start) return const <MediaNode>[];

    final int span = end - start;
    if (span <= browsePageSize) {
      return <MediaNode>[
        for (int i = start; i < end; i++) section.nodeAt(i),
      ];
    }

    int step = browsePageSize;
    while (span > step * browsePageSize) {
      step *= browsePageSize;
    }
    final List<MediaNode> pages = <MediaNode>[];
    for (int from = start; from < end; from += step) {
      final int to = from + step > end ? end : from + step;
      pages.add(MediaNode(
        // Browsable, never playable: the `page/` namespace resolves to nothing
        // in [resolve], so selecting a page row can't start playback.
        id: MediaId.browsePage(sectionId, from, to),
        title: '${from + 1} – $to',
        subtitle: '${_pageLabel(section.nodeAt(from))} … '
            '${_pageLabel(section.nodeAt(to - 1))}',
      ));
    }
    return pages;
  }

  /// A page row's endpoint hint: the child's title, shortened so a long track
  /// name can't push the row's subtitle out of the car's single line. Titles
  /// only — never a uri or a path.
  static String _pageLabel(MediaNode node) {
    const int maxLength = 24;
    final String title = node.title;
    if (title.length <= maxLength) return title;
    return '${title.substring(0, maxLength - 1).trimRight()}…';
  }

  /// Resolves a selected leaf [publishedId] to what should play, or null when
  /// it doesn't name a playable track (e.g. a stale id, or a
  /// category/container).
  ///
  /// A row published with the track it listed ([MediaId.listing]) plays that
  /// track wherever its list now has it, or nothing once it has left the list.
  Future<MediaPlaybackRequest?> resolve(
    String publishedId,
    PlaybackState playback,
  ) async {
    final ({String id, String? trackHash}) row =
        MediaId.listedTrackOf(publishedId);
    final String mediaId = row.id;
    final String? listed = row.trackHash;
    // A `page/` container is a browse-only node. It is checked first (and
    // explicitly) so a page row can never be played, even if a future leaf
    // namespace were to overlap it.
    if (MediaId.isBrowsePage(mediaId)) return null;
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
      return _requestAt(tracks, MediaId.albumTrackIndex(mediaId), listed);
    }
    if (MediaId.isArtistTrack(mediaId)) {
      final List<Track> tracks = tracksForArtist(
          await _allTracks(), MediaId.artistTrackArtistId(mediaId));
      return _requestAt(tracks, MediaId.artistTrackIndex(mediaId), listed);
    }
    if (MediaId.isQueueItem(mediaId)) {
      final List<Track> tracks = _currentQueue(playback);
      return _requestAt(tracks, _queuePosition(mediaId, tracks));
    }
    if (MediaId.isPlaylistTrack(mediaId)) {
      final List<Track> tracks =
          await _playlistTracks(MediaId.playlistTrackPlaylistId(mediaId));
      return _requestAt(tracks, MediaId.playlistTrackIndex(mediaId), listed);
    }
    if (MediaId.isFavoriteItem(mediaId)) {
      return _requestAt(
          await _favoriteTracks(), MediaId.favoriteIndex(mediaId), listed);
    }
    if (MediaId.isOfflineItem(mediaId)) {
      return _requestAt(
          await _offlineTracks(), MediaId.offlineIndex(mediaId), listed);
    }
    return null;
  }

  /// A request that starts [tracks] at [index], or null when the index is out of
  /// range (a stale leaf id whose list has since shrunk). With [listed], the
  /// hash of the track the row showed, it starts at that track instead,
  /// wherever the list has it now, and is null once it has left the list.
  MediaPlaybackRequest? _requestAt(
    List<Track> tracks,
    int index, [
    String? listed,
  ]) {
    final int at =
        listed == null ? index : _whereListedTrackIs(tracks, index, listed);
    if (at < 0 || at >= tracks.length) return null;
    return MediaPlaybackRequest(tracks: tracks, startIndex: at);
  }

  /// Where the Queue row [mediaId] points in the live queue of [playback]:
  /// its position counting the current track as 0 and up-next after it, or -1
  /// when the row no longer names a queued song.
  ///
  /// Synchronous, reading only [playback], so a caller can act on the answer
  /// before the queue can move again.
  int queuePositionOf(String mediaId, PlaybackState playback) =>
      MediaId.isQueueItem(mediaId)
          ? _queuePosition(mediaId, _currentQueue(playback))
          : -1;

  /// [queuePositionOf] within the live queue [tracks] (current, then up-next).
  static int _queuePosition(String mediaId, List<Track> tracks) {
    final int index = MediaId.queueIndex(mediaId);
    final String? listed = MediaId.queueTrackHash(mediaId);
    final int at =
        listed == null ? index : _whereListedTrackIs(tracks, index, listed);
    return at >= 0 && at < tracks.length ? at : -1;
  }

  /// Where the track a row was listed for ([trackHash], at [listedAt]) is in
  /// its list [tracks] now, or -1 when it is not there any more (it has played,
  /// left the list, or another queue replaced that one).
  ///
  /// The row's own position is checked first, which is the answer whenever the
  /// list has not changed. Otherwise the nearest copy of the song wins, the
  /// earlier one on a tie: a queue that moved on has moved the song towards the
  /// top, and a song listed twice keeps each row on its own copy.
  static int _whereListedTrackIs(
    List<Track> tracks,
    int listedAt,
    String trackHash,
  ) {
    if (listedAt < 0) return -1;
    bool listedHere(int i) =>
        i >= 0 &&
        i < tracks.length &&
        MediaId.libraryTrackHash(tracks[i].uri) == trackHash;
    for (int distance = 0;
        listedAt - distance >= 0 || listedAt + distance < tracks.length;
        distance++) {
      if (listedHere(listedAt - distance)) return listedAt - distance;
      if (distance > 0 && listedHere(listedAt + distance)) {
        return listedAt + distance;
      }
    }
    return -1;
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

  Future<bool> _hasOffline() async => (await _downloadedKeys()).isNotEmpty;

  /// The flat Songs section, kept *lazy*: it reports the catalog size and builds
  /// a leaf only for the index actually asked for. That is what keeps a 200k
  /// library cheap to browse — a page request materializes 250 nodes, not
  /// 200 000 of which 249 750 are immediately discarded.
  Future<_Section> _songSection() async {
    final List<Track> tracks = await _allTracks();
    if (tracks.isEmpty) {
      return _Section.of(_placeholder('Sync your library first'));
    }
    return _Section(
      tracks.length,
      // Key each leaf by a hash of the provider-namespaced uri so two same-id
      // songs from different providers get distinct, collision-free media ids —
      // and so a leaf id stays the same whichever page it was listed on.
      (int i) => _trackNode(MediaId.libraryTrack(tracks[i].uri), tracks[i]),
    );
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

  /// The Queue section, lazy like Songs: each row carries a hash of its track
  /// (see [MediaId.queueItem]), so only the rows a page returns are hashed,
  /// however long the queue.
  _Section _queueSection(PlaybackState playback) {
    final List<Track> tracks = _currentQueue(playback);
    return _Section(
      tracks.length,
      (int i) => _trackNode(MediaId.queueItem(i, tracks[i].uri), tracks[i]),
    );
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
    final Set<String> uris = await _favoriteIds();
    if (uris.isEmpty) return const <Track>[];
    final List<Track> tracks = await _allTracks();
    // Match on the provider-namespaced uri the favourites set now holds, so a
    // favourite on `jellyfin:101` never surfaces `subsonic:101` in the car.
    return <Track>[
      for (final Track track in tracks)
        if (uris.contains(track.uri)) track,
    ];
  }

  /// The downloaded (offline) tracks in stable catalog order, so an
  /// `offline/<index>` leaf listed and resolved in the same browse session
  /// refers to the same track. Only user-downloaded tracks appear — smart
  /// pre-cached tracks are deliberately not reported as downloaded by the
  /// repository, so they never leak into this section. Ids with no catalog track
  /// are dropped.
  Future<List<Track>> _offlineTracks() async {
    final Set<String> keys = await _downloadedKeys();
    if (keys.isEmpty) return const <Track>[];
    final List<Track> tracks = await _allTracks();
    return <Track>[
      for (final Track track in tracks)
        if (keys.contains(CachedTrack.cacheKeyForTrack(track))) track,
    ];
  }

  /// The tracks of playlist [playlistId] in playlist order, resolved against the
  /// catalog. Ids with no catalog track are dropped (can't be played).
  Future<List<Track>> _playlistTracks(String playlistId) async {
    final PlaylistRepository? playlists = _playlists;
    if (playlists == null) return const <Track>[];
    final Playlist? playlist = await _playlistById(playlists, playlistId);
    if (playlist == null || playlist.trackIds.isEmpty) return const <Track>[];
    // Resolve by the provider-namespaced uri the membership now stores, so a
    // `jellyfin:101` entry can't resolve to a same-id `subsonic:101` track.
    final Map<String, Track> byUri = <String, Track>{
      for (final Track track in await _allTracks()) track.uri: track,
    };
    return <Track>[
      for (final String uri in playlist.trackIds)
        if (byUri[uri] != null) byUri[uri]!,
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

  /// The current favourite track-uri set (provider-namespaced), read from the
  /// repository's stream (which yields the current set immediately). Guarded: any
  /// failure yields an empty set so a misbehaving favourites backend can't break
  /// browsing.
  Future<Set<String>> _favoriteIds() async {
    final FavoritesRepository? favorites = _favorites;
    if (favorites == null) return const <String>{};
    try {
      return await favorites.favoritesStream.first;
    } catch (_) {
      return const <String>{};
    }
  }

  /// The current downloaded cache-key set (provider-aware). Guarded: any failure
  /// yields an empty set so a misbehaving download backend can't break browsing.
  Future<Set<String>> _downloadedKeys() async {
    final DownloadRepository? downloads = _downloads;
    if (downloads == null) return const <String>{};
    try {
      return (await downloads.downloadedTrackKeys()).toSet();
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
  ///
  /// Served from a short-lived snapshot (see [_defaultCatalogSnapshotTtl]) so
  /// the burst of browse requests behind one car interaction costs a single
  /// catalog read and sees one consistent list — otherwise every page of a
  /// large library would re-scan the whole catalog, and a sync landing
  /// mid-scroll could shift the page windows underneath the user. Concurrent
  /// callers share the in-flight read rather than each starting their own.
  /// Failures are not cached, so a transient catalog error retries at once.
  Future<List<Track>> _allTracks() {
    final List<Track>? snapshot = _catalogSnapshot;
    final DateTime? takenAt = _catalogSnapshotAt;
    if (snapshot != null &&
        takenAt != null &&
        DateTime.now().difference(takenAt) < _catalogSnapshotTtl) {
      return Future<List<Track>>.value(snapshot);
    }
    return _catalogInFlight ??= _readCatalog();
  }

  Future<List<Track>> _readCatalog() async {
    try {
      final List<Track> tracks = await _library.getAllTracks();
      _catalogSnapshot = tracks;
      _catalogSnapshotAt = DateTime.now();
      return tracks;
    } catch (_) {
      return const <Track>[];
    } finally {
      _catalogInFlight = null;
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

/// A browse section as a lazily-indexable list of nodes: how many children it
/// has, and how to build the one at a given index.
///
/// Sections that are already materialized (albums, playlists, the queue) wrap
/// their list with [_Section.of]; the flat Songs section stays lazy so paging a
/// six-figure catalog builds only the page it returns.
@immutable
class _Section {
  const _Section(this.length, this.nodeAt);

  factory _Section.of(List<MediaNode> nodes) =>
      _Section(nodes.length, (int i) => nodes[i]);

  final int length;
  final MediaNode Function(int index) nodeAt;

  /// A section with no children — an unknown or dead-stop node.
  static const _Section empty = _Section(0, _noNode);
}

MediaNode _noNode(int index) =>
    throw StateError('empty browse section has no child at $index');
