import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import 'fake_browse_repositories.dart';

Track _track(String id, {String? artist, String? album, int? trackNumber}) {
  return Track(
    id: id,
    title: 'Song $id',
    uri: '/$id.mp3',
    artistName: artist,
    albumName: album,
    trackNumber: trackNumber,
  );
}

/// The provider-aware download cache keys for catalog ids built with [_track],
/// so a test can express downloaded tracks by plain id while the repository (and
/// the media browser) join on the cache key.
Set<String> _dlKeys(Iterable<String> ids) => <String>{
      for (final String id in ids) CachedTrack.cacheKeyForTrack(_track(id))
    };

PlaybackState _playing(Track current, {List<Track> upNext = const <Track>[]}) {
  return PlaybackState(
    status: PlaybackStatus.playing,
    currentTrack: current,
    upNext: upNext,
  );
}

/// Short call-site helpers (idle playback unless a queue is involved).
Future<List<MediaNode>> _kids(MediaBrowserTree t, String id) =>
    t.childrenOf(id, PlaybackState.idle);

Future<MediaPlaybackRequest?> _pick(MediaBrowserTree t, String id) =>
    t.resolve(id, PlaybackState.idle);

/// Walks a browse branch depth-first and returns its playable leaves in browse
/// order, descending through however many `page/` container levels the tree
/// chose. This is what "every song is still reachable" means from the car: a
/// user can always get to a track by opening rows, without the test having to
/// know the shape the tree picked.
Future<List<MediaNode>> _walkLeaves(MediaBrowserTree t, String parentId) async {
  final leaves = <MediaNode>[];
  for (final MediaNode node in await _kids(t, parentId)) {
    if (MediaId.isBrowsePage(node.id)) {
      leaves.addAll(await _walkLeaves(t, node.id));
    } else {
      leaves.add(node);
    }
  }
  return leaves;
}

Future<List<MediaNode>> _allSongLeaves(MediaBrowserTree t) =>
    _walkLeaves(t, MediaId.library);

/// A synthetic catalog of [n] tracks with realistic, distinct metadata.
List<Track> _bigCatalog(int n) => <Track>[
      for (int i = 0; i < n; i++)
        Track(
          id: 'jellyfin:$i',
          title: 'Song ${i.toString().padLeft(6, '0')}',
          uri: 'jellyfin:https://music.example.org/Items/$i/stream?api_key=SEC',
          artistName: 'Artist ${i % 500}',
          albumName: 'Album ${i % 2000}',
          artworkUri: Uri.parse(
              'https://music.example.org/Items/al-${i % 2000}/Images/Primary'),
        ),
    ];

void main() {
  group('MediaBrowserTree', () {
    final library = <Track>[
      _track('a', artist: 'Artist a', album: 'Album a'),
      _track('b', artist: 'Artist b'),
      _track('c'),
    ];

    MediaBrowserTree treeOf(List<Track> tracks) =>
        MediaBrowserTree(FakeMusicLibraryRepository(tracks: tracks));

    group('root', () {
      MediaBrowserTree treeWith({
        List<Track> tracks = const <Track>[],
        List<Playlist> playlists = const <Playlist>[],
        Set<String> favorites = const <String>{},
        Set<String> downloads = const <String>{},
      }) {
        return MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: tracks),
          playlists: FakePlaylistRepository(playlists),
          favorites: FakeFavoritesRepository(favorites),
          downloads: FakeDownloadRepository(_dlKeys(downloads)),
        );
      }

      test('always offers Songs, Albums, Artists and Queue', () async {
        // The library categories are always present (they reflect the catalog,
        // even when it is empty); the user-data categories are not, here.
        final nodes = await _kids(treeOf(library), MediaId.root);

        expect(nodes.map((n) => n.id), [
          MediaId.library,
          MediaId.albums,
          MediaId.artists,
          MediaId.queue,
        ]);
        expect(
            nodes.map((n) => n.title), ['Songs', 'Albums', 'Artists', 'Queue']);
        expect(nodes.every((n) => n.playable), isFalse);
      });

      test('contains every section, in order, when data exists', () async {
        final tree = treeWith(
          tracks: library,
          playlists: [const Playlist(id: 'p1', name: 'Roadtrip')],
          favorites: {'/a.mp3'},
          downloads: {'b'},
        );

        final nodes = await _kids(tree, MediaId.root);

        expect(nodes.map((n) => n.id), [
          MediaId.library,
          MediaId.albums,
          MediaId.artists,
          MediaId.playlists,
          MediaId.favorites,
          MediaId.offline,
          MediaId.queue,
        ]);
        expect(nodes.map((n) => n.title), [
          'Songs',
          'Albums',
          'Artists',
          'Playlists',
          'Favorites',
          'Offline',
          'Queue',
        ]);
        expect(nodes.every((n) => n.playable), isFalse);
      });

      test('Playlists appears only when a playlist exists', () async {
        expect(
          (await _kids(treeWith(tracks: library), MediaId.root))
              .map((n) => n.id),
          isNot(contains(MediaId.playlists)),
        );
        final tree = treeWith(
          tracks: library,
          playlists: [const Playlist(id: 'p1', name: 'Roadtrip')],
        );
        expect((await _kids(tree, MediaId.root)).map((n) => n.id),
            contains(MediaId.playlists));
      });

      test('Favorites appears only when a favourite exists', () async {
        expect(
          (await _kids(treeWith(tracks: library), MediaId.root))
              .map((n) => n.id),
          isNot(contains(MediaId.favorites)),
        );
        final tree = treeWith(tracks: library, favorites: {'/a.mp3'});
        expect((await _kids(tree, MediaId.root)).map((n) => n.id),
            contains(MediaId.favorites));
      });

      test('Offline appears only when a download exists', () async {
        expect(
          (await _kids(treeWith(tracks: library), MediaId.root))
              .map((n) => n.id),
          isNot(contains(MediaId.offline)),
        );
        final tree = treeWith(tracks: library, downloads: {'a'});
        expect((await _kids(tree, MediaId.root)).map((n) => n.id),
            contains(MediaId.offline));
      });

      test('browses from cold repositories before any UI', () async {
        // Depends only on repositories and a PlaybackState snapshot, never on a
        // widget, so Android Auto can load it the moment the service starts.
        final tree = treeWith(
          tracks: library,
          playlists: [const Playlist(id: 'p1', name: 'Roadtrip')],
          favorites: {'/a.mp3'},
          downloads: {'b'},
        );

        final root = await _kids(tree, MediaId.root);
        final songs = await _kids(tree, MediaId.library);
        final albums = await _kids(tree, MediaId.albums);

        expect(root, isNotEmpty);
        expect(songs, isNotEmpty);
        expect(albums, isNotEmpty);
      });
    });

    group('songs', () {
      test('exposes every catalog track as a playable leaf', () async {
        final nodes = await _kids(treeOf(library), MediaId.library);

        // Leaves are keyed by an opaque hash of the track uri (collision-free
        // across providers); libraryTrack() does the hashing, so we compare to
        // it built from each track's uri.
        expect(nodes.map((n) => n.id), [
          MediaId.libraryTrack('/a.mp3'),
          MediaId.libraryTrack('/b.mp3'),
          MediaId.libraryTrack('/c.mp3'),
        ]);
        expect(nodes.every((n) => n.playable), isTrue);
        expect(nodes.first.track, library.first);
      });

      test('track subtitle joins the present artist/album parts', () async {
        final nodes = await _kids(treeOf(library), MediaId.library);

        expect(nodes[0].subtitle, 'Artist a • Album a');
        expect(nodes[1].subtitle, 'Artist b');
        expect(nodes[2].subtitle, isNull);
      });

      test('an empty catalog shows a friendly placeholder', () async {
        final nodes = await _kids(treeOf(const <Track>[]), MediaId.library);

        expect(nodes.single.title, 'Sync your library first');
        expect(nodes.single.playable, isFalse);
        expect(nodes.single.id, MediaId.empty);
        // Browsing into the placeholder is a safe dead-stop, not a crash.
        expect(await _kids(treeOf(const <Track>[]), MediaId.empty), isEmpty);
      });

      test('a library track resolves to the whole catalog at its index',
          () async {
        final request =
            await _pick(treeOf(library), MediaId.libraryTrack('/b.mp3'));

        expect(request, isNotNull);
        expect(request!.tracks, library);
        expect(request.startIndex, 1);
      });

      test('a missing library track resolves to null', () async {
        expect(
          await _pick(treeOf(library), MediaId.libraryTrack('/zzz.mp3')),
          isNull,
        );
      });

      test(
          'same bare-id songs from different providers get distinct media ids '
          'and resolve to the right copy', () async {
        const jelly = Track(id: '101', title: 'Alpha', uri: 'jellyfin:101');
        const sub = Track(id: '101', title: 'Beta', uri: 'subsonic:101');
        final tree = treeOf(<Track>[jelly, sub]);

        final nodes = await _kids(tree, MediaId.library);
        // Distinct, collision-free leaf ids (would have collided on the bare id).
        final List<String> ids = nodes.map((n) => n.id).toList();
        expect(ids, <String>[
          MediaId.libraryTrack('jellyfin:101'),
          MediaId.libraryTrack('subsonic:101'),
        ]);
        expect(ids[0], isNot(ids[1]));

        // Each leaf resolves to its own provider copy, not whichever shares 101.
        final jReq = await _pick(tree, MediaId.libraryTrack('jellyfin:101'));
        final sReq = await _pick(tree, MediaId.libraryTrack('subsonic:101'));
        expect(jReq!.tracks[jReq.startIndex].uri, 'jellyfin:101');
        expect(sReq!.tracks[sReq.startIndex].uri, 'subsonic:101');
      });
    });

    group('albums', () {
      // Two tracks of one album, deliberately out of track-number order, plus a
      // standalone track, so album grouping and album ordering are both tested.
      final catalog = <Track>[
        _track('t2', album: 'Discovery', artist: 'Daft Punk', trackNumber: 2),
        _track('t1', album: 'Discovery', artist: 'Daft Punk', trackNumber: 1),
        _track('s', album: 'Solo', artist: 'Someone'),
      ];

      test('lists albums as browsable containers, with art and artist subtitle',
          () async {
        final albums = groupAlbums(catalog);
        final nodes = await _kids(treeOf(catalog), MediaId.albums);

        expect(nodes.map((n) => n.id),
            [for (final a in albums) MediaId.album(a.id)]);
        expect(nodes.map((n) => n.title), albums.map((a) => a.title));
        expect(nodes.map((n) => n.subtitle), albums.map((a) => a.artistName));
        expect(nodes.every((n) => n.playable), isFalse);
      });

      test('an empty catalog shows a friendly placeholder', () async {
        final nodes = await _kids(treeOf(const <Track>[]), MediaId.albums);

        expect(nodes.single.title, 'No albums yet');
        expect(nodes.single.playable, isFalse);
      });

      test('opening an album lists its tracks in track-number order', () async {
        final albumId = albumIdForTrack(catalog.first); // Discovery
        final nodes = await _kids(treeOf(catalog), MediaId.album(albumId));

        // t1 before t2 despite catalog order, by track number.
        expect(nodes.map((n) => n.title), ['Song t1', 'Song t2']);
        expect(nodes.map((n) => n.id), [
          MediaId.albumTrack(albumId, 0),
          MediaId.albumTrack(albumId, 1),
        ]);
        expect(nodes.every((n) => n.playable), isTrue);
      });

      test('selecting an album track plays the album queue at its index',
          () async {
        final albumId = albumIdForTrack(catalog.first);
        final request =
            await _pick(treeOf(catalog), MediaId.albumTrack(albumId, 1));

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['t1', 't2']);
        expect(request.startIndex, 1);
      });

      test('an out-of-range or unknown album id is safe', () async {
        final albumId = albumIdForTrack(catalog.first);
        expect(await _pick(treeOf(catalog), MediaId.albumTrack(albumId, 9)),
            isNull);
        expect(await _pick(treeOf(catalog), MediaId.albumTrack('nope', 0)),
            isNull);
        expect(await _kids(treeOf(catalog), MediaId.album('nope')), isEmpty);
      });

      // Issue #682: album-less tracks by different artists used to share one
      // Unknown Album, so playing it queued every artist's loose tracks.
      test('an Unknown Album queue holds only its own artist\'s tracks',
          () async {
        final loose = <Track>[
          _track('a2', artist: 'Artist A', trackNumber: 2),
          _track('b1', artist: 'Artist B', trackNumber: 1),
          _track('a1', artist: 'Artist A', trackNumber: 1),
          _track('x1'),
        ];
        final tree = treeOf(loose);
        final albumId = albumIdForTrack(loose.first);

        final albums = await _kids(tree, MediaId.albums);
        final request = await _pick(tree, MediaId.albumTrack(albumId, 0));

        expect(albums.where((n) => n.title == kUnknownAlbum), hasLength(3));
        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['a1', 'a2']);
      });
    });

    group('artists', () {
      final catalog = <Track>[
        _track('m1', album: 'Discovery', artist: 'Daft Punk', trackNumber: 1),
        _track('m2', album: 'Homework', artist: 'Daft Punk', trackNumber: 1),
        _track('s', album: 'Solo', artist: 'Someone'),
      ];

      test('lists artists as browsable containers with a summary subtitle',
          () async {
        final artists = groupArtists(catalog);
        final nodes = await _kids(treeOf(catalog), MediaId.artists);

        expect(nodes.map((n) => n.id),
            [for (final a in artists) MediaId.artist(a.id)]);
        expect(nodes.map((n) => n.title), artists.map((a) => a.name));
        expect(nodes.every((n) => n.playable), isFalse);
        // Daft Punk: 2 albums • 2 songs.
        final daft = nodes.firstWhere((n) => n.title == 'Daft Punk');
        expect(daft.subtitle, '2 albums • 2 songs');
      });

      test('an empty catalog shows a friendly placeholder', () async {
        final nodes = await _kids(treeOf(const <Track>[]), MediaId.artists);

        expect(nodes.single.title, 'No artists yet');
        expect(nodes.single.playable, isFalse);
      });

      test('opening an artist lists their tracks, album by album', () async {
        final artistId = artistIdForTrack(catalog.first); // Daft Punk
        final nodes = await _kids(treeOf(catalog), MediaId.artist(artistId));

        // Both Daft Punk tracks, ordered by album (Discovery before Homework).
        expect(nodes.map((n) => n.title), ['Song m1', 'Song m2']);
        expect(nodes.map((n) => n.id), [
          MediaId.artistTrack(artistId, 0),
          MediaId.artistTrack(artistId, 1),
        ]);
        expect(nodes.every((n) => n.playable), isTrue);
      });

      test('selecting an artist track plays the artist queue at its index',
          () async {
        final artistId = artistIdForTrack(catalog.first);
        final request =
            await _pick(treeOf(catalog), MediaId.artistTrack(artistId, 1));

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['m1', 'm2']);
        expect(request.startIndex, 1);
      });

      test('an out-of-range or unknown artist id is safe', () async {
        final artistId = artistIdForTrack(catalog.first);
        expect(await _pick(treeOf(catalog), MediaId.artistTrack(artistId, 9)),
            isNull);
        expect(await _pick(treeOf(catalog), MediaId.artistTrack('nope', 0)),
            isNull);
        expect(await _kids(treeOf(catalog), MediaId.artist('nope')), isEmpty);
      });
    });

    group('queue', () {
      test('lists the current track followed by up-next', () async {
        final playback = _playing(library[0], upNext: [library[1], library[2]]);

        final nodes = await treeOf(library).childrenOf(MediaId.queue, playback);

        // Each row carries its position and the opaque hash of the track it
        // listed.
        String row(int index) => '${MediaId.queueItem(index)}/'
            '${MediaId.libraryTrackHash(library[index].uri)}';
        expect(nodes.map((n) => n.title), ['Song a', 'Song b', 'Song c']);
        expect(nodes.map((n) => n.id), [row(0), row(1), row(2)]);
      });

      test('is empty when nothing is playing', () async {
        expect(await _kids(treeOf(library), MediaId.queue), isEmpty);
      });

      test('a queue item resolves to the live queue at its index', () async {
        final playback = _playing(library[0], upNext: [library[1], library[2]]);

        final request =
            await treeOf(library).resolve(MediaId.queueItem(2), playback);

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['a', 'b', 'c']);
        expect(request.startIndex, 2);
      });

      test('a row resolves to the song it listed after the queue moved on',
          () async {
        final MediaBrowserTree tree = treeOf(library);
        final List<MediaNode> rows = await tree.childrenOf(MediaId.queue,
            _playing(library[0], upNext: [library[1], library[2]]));
        // Song a ended while the car still shows that list.
        final PlaybackState movedOn =
            _playing(library[1], upNext: [library[2]]);

        final request = await tree.resolve(rows[2].id, movedOn);
        expect(request, isNotNull);
        expect(request!.tracks[request.startIndex], library[2]);
        expect(await tree.resolve(rows[0].id, movedOn), isNull,
            reason: 'Song a has played; the row must not start another song');
      });

      test('a song queued twice keeps each row on its own copy', () async {
        final Track a = library[0];
        final Track b = library[1];
        final Track c = library[2];
        final MediaBrowserTree tree = treeOf(library);
        final List<MediaNode> rows = await tree.childrenOf(
            MediaId.queue, _playing(a, upNext: [b, a, c]));
        // The first Song a ended: the second one moved up from row 2 to row 1.
        final PlaybackState movedOn = _playing(b, upNext: [a, c]);

        final request = await tree.resolve(rows[2].id, movedOn);
        expect(request, isNotNull);
        expect(request!.startIndex, 1);
        expect(request.tracks[1], a);
      });

      test('an out-of-range / non-numeric queue id resolves to null', () async {
        expect(
          await treeOf(library)
              .resolve(MediaId.queueItem(5), _playing(library[0])),
          isNull,
        );
        expect(
          await treeOf(library)
              .resolve('queue/not-a-number', PlaybackState.idle),
          isNull,
        );
      });

      test('an unknown parent id and a category are safe', () async {
        expect(await _kids(treeOf(library), 'nonsense'), isEmpty);
        expect(await _pick(treeOf(library), MediaId.library), isNull);
        expect(await _pick(treeOf(library), MediaId.root), isNull);
        expect(await _pick(treeOf(library), MediaId.albums), isNull);
      });
    });

    group('playlists', () {
      final playlists = <Playlist>[
        // '/x.mp3' is not in the catalog and must be dropped (can't be played).
        const Playlist(
            id: 'p1',
            name: 'Roadtrip',
            trackIds: ['/c.mp3', '/a.mp3', '/x.mp3']),
        const Playlist(id: 'p2', name: 'Empty'),
      ];

      MediaBrowserTree buildTree() {
        return MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: library),
          playlists: FakePlaylistRepository(playlists),
        );
      }

      test('lists each playlist as a browsable container', () async {
        final nodes = await _kids(buildTree(), MediaId.playlists);

        expect(nodes.map((n) => n.id), [
          MediaId.playlist('p1'),
          MediaId.playlist('p2'),
        ]);
        expect(nodes.map((n) => n.title), ['Roadtrip', 'Empty']);
        expect(nodes.map((n) => n.subtitle), ['3 tracks', '0 tracks']);
        expect(nodes.every((n) => n.playable), isFalse);
      });

      test('no playlists shows a friendly placeholder', () async {
        final tree = MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: library),
          playlists: FakePlaylistRepository(const <Playlist>[]),
        );
        expect((await _kids(tree, MediaId.playlists)).single.title,
            'No playlists yet');
      });

      test('opening a playlist lists its tracks in order', () async {
        final nodes = await _kids(buildTree(), MediaId.playlist('p1'));

        // 'c' then 'a' (playlist order); 'x' dropped.
        expect(nodes.map((n) => n.title), ['Song c', 'Song a']);
        expect(nodes.map((n) => n.id), [
          MediaId.playlistTrack('p1', 0),
          MediaId.playlistTrack('p1', 1),
        ]);
        expect(nodes.every((n) => n.playable), isTrue);
      });

      test('an empty playlist yields no track nodes', () async {
        expect(await _kids(buildTree(), MediaId.playlist('p2')), isEmpty);
      });

      test('a playlist track resolves to the playlist at its index', () async {
        final request =
            await _pick(buildTree(), MediaId.playlistTrack('p1', 1));

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['c', 'a']);
        expect(request.startIndex, 1);
      });

      test('an out-of-range / unknown playlist id is safe', () async {
        expect(
            await _pick(buildTree(), MediaId.playlistTrack('p1', 9)), isNull);
        expect(
            await _pick(buildTree(), MediaId.playlistTrack('nope', 0)), isNull);
        expect(await _kids(buildTree(), MediaId.playlist('nope')), isEmpty);
      });

      test('a member resolves to its own provider, not a same-id sibling',
          () async {
        const Track jelly =
            Track(id: '101', title: 'Alpha', uri: 'jellyfin:101');
        const Track sub = Track(id: '101', title: 'Beta', uri: 'subsonic:101');
        final tree = MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: const <Track>[jelly, sub]),
          playlists: FakePlaylistRepository(<Playlist>[
            const Playlist(
                id: 'p1', name: 'Mix', trackIds: <String>['jellyfin:101']),
          ]),
        );

        final nodes = await _kids(tree, MediaId.playlist('p1'));
        // The `jellyfin:101` entry resolves to the Jellyfin track only.
        expect(nodes.map((n) => n.title), <String>['Alpha']);
      });
    });

    group('favorites', () {
      // Catalog order is a, b, c; favouriting a and c (plus a stale '/x.mp3' not
      // in the catalog) must list/resolve as [a, c] in catalog order. Favourites
      // are keyed by uri, matching _track's '/$id.mp3'.
      MediaBrowserTree buildTree(
          [Set<String> uris = const {'/a.mp3', '/c.mp3', '/x.mp3'}]) {
        return MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: library),
          favorites: FakeFavoritesRepository(uris),
        );
      }

      test('lists favourites in stable catalog order', () async {
        final nodes = await _kids(buildTree(), MediaId.favorites);

        expect(nodes.map((n) => n.title), ['Song a', 'Song c']);
        expect(nodes.map((n) => n.id), [
          MediaId.favoriteItem(0),
          MediaId.favoriteItem(1),
        ]);
        expect(nodes.every((n) => n.playable), isTrue);
      });

      test('no favourites shows a friendly placeholder', () async {
        expect(
            (await _kids(buildTree(const <String>{}), MediaId.favorites))
                .single
                .title,
            'No favorites yet');
      });

      test('a favourite resolves to the favourites at its index', () async {
        final request = await _pick(buildTree(), MediaId.favoriteItem(1));

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['a', 'c']);
        expect(request.startIndex, 1);
      });

      test('an out-of-range favourite index resolves to null', () async {
        expect(await _pick(buildTree(), MediaId.favoriteItem(9)), isNull);
      });

      test('a favourite on one provider never surfaces a same-id sibling',
          () async {
        const Track jelly =
            Track(id: '101', title: 'Alpha', uri: 'jellyfin:101');
        const Track sub = Track(id: '101', title: 'Beta', uri: 'subsonic:101');
        final tree = MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: const <Track>[jelly, sub]),
          favorites: FakeFavoritesRepository(const <String>{'jellyfin:101'}),
        );

        final nodes = await _kids(tree, MediaId.favorites);
        // Only the favourited copy appears — not its same-id Subsonic sibling.
        expect(nodes.map((n) => n.title), <String>['Alpha']);
      });
    });

    group('offline', () {
      // Downloaded ids b and c (plus a stale 'x' not in the catalog) list and
      // resolve as [b, c] in catalog order, exactly like favourites.
      MediaBrowserTree buildTree([Set<String> ids = const {'b', 'c', 'x'}]) {
        return MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: library),
          downloads: FakeDownloadRepository(_dlKeys(ids)),
        );
      }

      test('lists downloaded tracks in stable catalog order', () async {
        final nodes = await _kids(buildTree(), MediaId.offline);

        expect(nodes.map((n) => n.title), ['Song b', 'Song c']);
        expect(nodes.map((n) => n.id), [
          MediaId.offlineItem(0),
          MediaId.offlineItem(1),
        ]);
        expect(nodes.every((n) => n.playable), isTrue);
      });

      test('no downloads shows a friendly placeholder', () async {
        expect(
            (await _kids(buildTree(const <String>{}), MediaId.offline))
                .single
                .title,
            'No offline tracks yet');
      });

      test('a downloaded track resolves to the offline list at its index',
          () async {
        final request = await _pick(buildTree(), MediaId.offlineItem(1));

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['b', 'c']);
        expect(request.startIndex, 1);
      });

      test('an out-of-range offline index resolves to null', () async {
        expect(await _pick(buildTree(), MediaId.offlineItem(9)), isNull);
      });
    });

    group('large catalogs are browsed from the local repository only', () {
      // A repo that records how many times the catalog was read, so we can show
      // browsing never reaches past it to a remote server (the tree has no
      // source/server seam at all — only this local repository).
      test('browsing a large catalog reads only the synced catalog', () async {
        final big = <Track>[
          for (int i = 0; i < 600; i++)
            _track('t$i',
                artist: 'Artist ${i % 50}', album: 'Album ${i % 100}'),
        ];
        final repo = _CountingLibraryRepository(big);
        final tree = MediaBrowserTree(repo);

        // 600 songs is past the browse bound, so Songs answers with the page
        // containers that span them; albums/artists are below it and stay flat.
        final songs = await _kids(tree, MediaId.library);
        final albums = await _kids(tree, MediaId.albums);
        final artists = await _kids(tree, MediaId.artists);

        expect(songs, hasLength(3)); // 0-250, 250-500, 500-600
        expect(await _allSongLeaves(tree), hasLength(600));
        expect(albums, hasLength(groupAlbums(big).length));
        expect(artists, hasLength(groupArtists(big).length));
        // One bounded catalog read serves the whole browse burst — no per-track
        // fan-out, no remote call, and no re-scan per section or per page.
        expect(repo.getAllTracksCalls, 1);
      });
    });

    // Regression coverage for #539: Android Auto's Songs branch used to answer
    // with one MediaItem per catalog track. Past ~1.5k tracks that single
    // response outgrows the media browser's ~1 MB Binder transaction, the
    // RemoteException is swallowed by MediaBrowserServiceCompat, and the car
    // never receives onChildrenLoaded — the endless "scanning" spinner. Songs is
    // now served as deterministic `page/` containers so no response can outgrow
    // the transaction, while every song stays reachable.
    group('large Songs catalogs are browsed in bounded pages (#539)', () {
      const int pageSize = MediaBrowserTree.browsePageSize;

      // Deliberately not a multiple of the page size, so the last page is a
      // partial one and the page boundaries are exercised for real.
      final huge = _bigCatalog(3 * pageSize * pageSize + 137); // 187 637 tracks

      MediaBrowserTree bigTree([List<Track>? tracks]) =>
          MediaBrowserTree(FakeMusicLibraryRepository(
              tracks: tracks ?? _bigCatalog(4 * pageSize + 7)));

      test('no browse response ever exceeds the page bound', () async {
        final tree = MediaBrowserTree(FakeMusicLibraryRepository(tracks: huge));

        // Walk the whole Songs branch and assert the bound holds at every node,
        // not just the top one.
        Future<void> checkNode(String id, int depth) async {
          final nodes = await _kids(tree, id);
          expect(nodes.length, lessThanOrEqualTo(pageSize),
              reason: 'node $id returned ${nodes.length} children');
          if (depth == 0) return;
          for (final node in nodes) {
            if (MediaId.isBrowsePage(node.id)) {
              await checkNode(node.id, depth - 1);
            }
          }
        }

        await checkNode(MediaId.library, 3);
      });

      test('every song is reachable exactly once, in catalog order', () async {
        final catalog = _bigCatalog(4 * pageSize + 7);
        final tree =
            MediaBrowserTree(FakeMusicLibraryRepository(tracks: catalog));

        final leaves = await _allSongLeaves(tree);

        expect(leaves, hasLength(catalog.length));
        // Same order as the catalog, and every leaf is a distinct playable song.
        expect(
          leaves.map((n) => n.track!.uri),
          catalog.map((t) => t.uri),
        );
        expect(leaves.map((n) => n.id).toSet(), hasLength(catalog.length));
        expect(leaves.every((n) => n.playable), isTrue);
      });

      test('page containers tile the catalog with no gap or overlap', () async {
        final catalog = _bigCatalog(4 * pageSize + 7);
        final tree =
            MediaBrowserTree(FakeMusicLibraryRepository(tracks: catalog));

        final pages = await _kids(tree, MediaId.library);
        expect(pages.length, 5); // 4 full pages + the 7-track remainder
        expect(pages.every((p) => MediaId.isBrowsePage(p.id)), isTrue);

        int expectedStart = 0;
        for (final MediaNode page in pages) {
          final BrowsePage window = MediaId.browsePageOf(page.id)!;
          expect(window.sectionId, MediaId.library);
          expect(window.start, expectedStart);
          final children = await _kids(tree, page.id);
          expect(children, hasLength(window.end - window.start));
          expect(
            children.map((n) => n.track!.uri),
            catalog.sublist(window.start, window.end).map((t) => t.uri),
          );
          expectedStart = window.end;
        }
        expect(expectedStart, catalog.length);
      });

      test('the first and last tracks are both reachable and playable',
          () async {
        final catalog = _bigCatalog(4 * pageSize + 7);
        final tree =
            MediaBrowserTree(FakeMusicLibraryRepository(tracks: catalog));

        final leaves = await _allSongLeaves(tree);

        expect(leaves.first.id, MediaId.libraryTrack(catalog.first.uri));
        expect(leaves.last.id, MediaId.libraryTrack(catalog.last.uri));

        for (final int index in <int>[0, catalog.length - 1]) {
          final request = await _pick(tree, leaves[index].id);
          expect(request, isNotNull);
          expect(request!.startIndex, index);
          expect(request.tracks, hasLength(catalog.length));
          expect(request.tracks[request.startIndex].uri, catalog[index].uri);
        }
      });

      test('a track picked from a page plays the whole catalog at its index',
          () async {
        final catalog = _bigCatalog(4 * pageSize + 7);
        final tree =
            MediaBrowserTree(FakeMusicLibraryRepository(tracks: catalog));

        // Straddle a page boundary: the last row of page 1 and the first of
        // page 2 must resolve to adjacent catalog positions.
        final pages = await _kids(tree, MediaId.library);
        final firstPage = await _kids(tree, pages[0].id);
        final secondPage = await _kids(tree, pages[1].id);

        final lastOfFirst = await _pick(tree, firstPage.last.id);
        final firstOfSecond = await _pick(tree, secondPage.first.id);

        expect(lastOfFirst!.startIndex, pageSize - 1);
        expect(firstOfSecond!.startIndex, pageSize);
        expect(lastOfFirst.tracks, hasLength(catalog.length));
        expect(firstOfSecond.tracks, hasLength(catalog.length));
        expect(firstOfSecond.tracks[firstOfSecond.startIndex].uri,
            catalog[pageSize].uri);
      });

      test('leaf ids are stable across repeated browses, and page ids too',
          () async {
        final tree = bigTree();

        final firstPass = await _allSongLeaves(tree);
        final firstPages =
            (await _kids(tree, MediaId.library)).map((n) => n.id).toList();
        final secondPass = await _allSongLeaves(tree);
        final secondPages =
            (await _kids(tree, MediaId.library)).map((n) => n.id).toList();

        expect(secondPages, firstPages);
        expect(secondPass.map((n) => n.id), firstPass.map((n) => n.id));
        expect(secondPass.map((n) => n.title), firstPass.map((n) => n.title));
      });

      test('repeated browses reuse one catalog snapshot (no rescan loop)',
          () async {
        final repo = _CountingLibraryRepository(_bigCatalog(4 * pageSize + 7));
        final tree = MediaBrowserTree(repo);

        final pages = await _kids(tree, MediaId.library);
        for (final page in pages) {
          await _kids(tree, page.id);
        }
        await _kids(tree, MediaId.library);
        await _kids(tree, MediaId.albums);

        // Android Auto (and audio_service's own seeded re-request) browses the
        // same branch repeatedly; that must not re-scan the catalog each time.
        expect(repo.getAllTracksCalls, 1);
      });

      test('concurrent browse requests share a single catalog read', () async {
        final repo = _CountingLibraryRepository(_bigCatalog(4 * pageSize + 7));
        final tree = MediaBrowserTree(repo);

        await Future.wait(<Future<List<MediaNode>>>[
          _kids(tree, MediaId.library),
          _kids(tree, MediaId.albums),
          _kids(tree, MediaId.artists),
        ]);

        expect(repo.getAllTracksCalls, 1);
      });

      test('a page container is browsable, never playable', () async {
        final tree = bigTree();
        final pages = await _kids(tree, MediaId.library);

        expect(pages.every((p) => p.playable), isFalse);
        expect(pages.every((p) => p.track == null), isTrue);
        for (final page in pages) {
          expect(await _pick(tree, page.id), isNull);
        }
      });

      test('duplicate provider-side bare ids stay distinct across pages',
          () async {
        // Two providers whose songs share bare ids 0..n, interleaved so the
        // colliding pair lands on different pages.
        const int n = pageSize + 4;
        final catalog = <Track>[
          for (int i = 0; i < n; i++)
            Track(id: '$i', title: 'Song $i', uri: 'jellyfin:$i'),
          for (int i = 0; i < n; i++)
            Track(id: '$i', title: 'Song $i', uri: 'subsonic:$i'),
        ];
        final tree =
            MediaBrowserTree(FakeMusicLibraryRepository(tracks: catalog));

        final leaves = await _allSongLeaves(tree);

        expect(leaves.map((n) => n.id).toSet(), hasLength(catalog.length));
        final jellyfin = await _pick(tree, MediaId.libraryTrack('jellyfin:7'));
        final subsonic = await _pick(tree, MediaId.libraryTrack('subsonic:7'));
        expect(jellyfin!.tracks[jellyfin.startIndex].uri, 'jellyfin:7');
        expect(subsonic!.tracks[subsonic.startIndex].uri, 'subsonic:7');
      });

      test('page ids and paged leaf ids stay secret-free', () async {
        final tree = bigTree();

        Future<void> expectSafe(String parentId, int depth) async {
          for (final MediaNode node in await _kids(tree, parentId)) {
            for (final String text in <String>[
              node.id,
              node.title,
              node.subtitle ?? '',
            ]) {
              expect(text, isNot(contains('api_key')));
              expect(text.toLowerCase(), isNot(contains('token')));
              expect(text, isNot(contains('jellyfin:')));
              expect(text, isNot(contains('://')));
            }
            if (depth > 0 && MediaId.isBrowsePage(node.id)) {
              await expectSafe(node.id, depth - 1);
            }
          }
        }

        await expectSafe(MediaId.library, 2);
      });

      test('a catalog at exactly the bound is still one flat list', () async {
        final tree = bigTree(_bigCatalog(pageSize));

        final nodes = await _kids(tree, MediaId.library);

        expect(nodes, hasLength(pageSize));
        expect(nodes.every((n) => n.playable), isTrue);
        expect(nodes.any((n) => MediaId.isBrowsePage(n.id)), isFalse);
      });

      test('one track past the bound switches to pages', () async {
        final tree = bigTree(_bigCatalog(pageSize + 1));

        final nodes = await _kids(tree, MediaId.library);

        expect(nodes, hasLength(2));
        expect(nodes.every((n) => MediaId.isBrowsePage(n.id)), isTrue);
        expect(await _allSongLeaves(tree), hasLength(pageSize + 1));
      });

      test('a six-figure catalog nests pages instead of widening them',
          () async {
        final tree = MediaBrowserTree(FakeMusicLibraryRepository(tracks: huge));

        final top = await _kids(tree, MediaId.library);
        expect(top, hasLength(4)); // 3 full pageSize^2 blocks + a remainder
        expect(top.every((n) => MediaId.isBrowsePage(n.id)), isTrue);

        // The first block splits again rather than returning 62 500 rows.
        final second = await _kids(tree, top.first.id);
        expect(second, hasLength(pageSize));
        expect(second.every((n) => MediaId.isBrowsePage(n.id)), isTrue);

        // And the third level is real songs.
        final third = await _kids(tree, second.first.id);
        expect(third, hasLength(pageSize));
        expect(third.every((n) => n.playable), isTrue);
        expect(third.first.id, MediaId.libraryTrack(huge.first.uri));

        // The tail block covers the odd 137-track remainder. It is already
        // under the bound, so it holds songs directly rather than splitting
        // again — and it ends on the catalog's very last track.
        final tail = await _kids(tree, top.last.id);
        expect(tail, hasLength(137));
        expect(tail.every((n) => n.playable), isTrue);
        expect(tail.last.id, MediaId.libraryTrack(huge.last.uri));
      });

      test('an empty catalog still shows the friendly placeholder', () async {
        final tree = MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: const <Track>[]));

        final nodes = await _kids(tree, MediaId.library);

        expect(nodes.single.id, MediaId.empty);
        expect(nodes.single.title, 'Sync your library first');
        expect(nodes.single.playable, isFalse);
      });

      test('a stale or malformed page id is a safe dead-stop', () async {
        final tree = bigTree();

        for (final String id in <String>[
          MediaId.browsePage(MediaId.library, 900000, 900250), // past the end
          MediaId.browsePage('nope', 0, 250), // unknown section
          'page/', // no section, no window
          'page/library/notanumber', // no window
          'page/library/250-100', // inverted window
          'page/library/-5-10', // negative start
          'page/page/library/0-250', // nested page
        ]) {
          expect(await _kids(tree, id), isEmpty, reason: id);
          expect(await _pick(tree, id), isNull, reason: id);
        }
      });

      test('the catalog snapshot is a TTL, not a freeze', () async {
        // With no TTL every browse re-reads, so a library that changed between
        // two browses is still picked up — the snapshot only collapses a burst.
        final repo = _CountingLibraryRepository(_bigCatalog(4 * pageSize + 7));
        final tree = MediaBrowserTree(repo, catalogSnapshotTtl: Duration.zero);

        await _kids(tree, MediaId.library);
        await _kids(tree, MediaId.library);

        expect(repo.getAllTracksCalls, 2);
      });

      // The bound is generic, so the same defect latent in the other flat
      // sections is fixed by the same code — no section-specific paging.
      test('large Albums and Artists sections are bounded and complete',
          () async {
        // Enough distinct albums/artists to blow past the bound on both.
        final catalog = <Track>[
          for (int i = 0; i < 2 * pageSize + 11; i++)
            _track('t$i', artist: 'Artist $i', album: 'Album $i'),
        ];
        final tree =
            MediaBrowserTree(FakeMusicLibraryRepository(tracks: catalog));

        for (final String section in <String>[
          MediaId.albums,
          MediaId.artists,
        ]) {
          final pages = await _kids(tree, section);
          expect(pages, hasLength(3), reason: section);
          expect(pages.every((n) => MediaId.isBrowsePage(n.id)), isTrue,
              reason: section);

          final containers = await _walkLeaves(tree, section);
          expect(containers, hasLength(catalog.length), reason: section);
          expect(containers.map((n) => n.id).toSet(), hasLength(catalog.length),
              reason: section);
          // Album/artist rows stay browsable containers, as before.
          expect(containers.every((n) => n.playable), isFalse, reason: section);
        }

        // And opening one of those containers still lists its tracks.
        final firstAlbum = (await _walkLeaves(tree, MediaId.albums)).first;
        final tracks = await _kids(tree, firstAlbum.id);
        expect(tracks, hasLength(1));
        expect(tracks.single.playable, isTrue);
      });

      test('a page whose section shrank clamps to what still exists', () async {
        // A page id minted for a 4-page catalog, replayed against a catalog that
        // has since shrunk to a partial final page.
        final wide =
            MediaId.browsePage(MediaId.library, pageSize, 2 * pageSize);
        final tree = bigTree(_bigCatalog(pageSize + 10));

        final nodes = await _kids(tree, wide);

        expect(nodes, hasLength(10));
        expect(nodes.every((n) => n.playable), isTrue);
      });
    });

    group('safe media ids', () {
      final jellyfin = Track(
        id: 'jf-guid-123',
        title: 'Remote Song',
        uri: 'jellyfin:jf-guid-123',
        artistName: 'Remote Artist',
        albumName: 'Remote Album',
        artworkUri: Uri.parse(
          'https://music.example.com/Items/jf-guid-123/Images/Primary',
        ),
      );
      const localTrack = Track(
        id: 'local-1',
        title: 'Local Song',
        uri: '/storage/music/local.mp3',
      );

      void expectSafeId(String id) {
        expect(id, isNot(contains('api_key')));
        expect(id.toLowerCase(), isNot(contains('token')));
        expect(id, isNot(contains('jellyfin:')));
        expect(id, isNot(contains('://')));
        expect(id, isNot(contains('/storage/')));
      }

      test('songs, albums and artists all map to token-free ids and art',
          () async {
        final tree = MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: <Track>[jellyfin, localTrack]),
        );

        for (final parent in <String>[
          MediaId.library,
          MediaId.albums,
          MediaId.artists,
        ]) {
          for (final node in await _kids(tree, parent)) {
            expectSafeId(node.id);
            expect(node.title.isNotEmpty, isTrue);
            // Container artwork (when present) is the token-free image endpoint,
            // never a credentialed/stream URL or a local path.
            final String art = node.artworkUri?.toString() ?? '';
            expect(art, isNot(contains('api_key')));
            expect(art.toLowerCase(), isNot(contains('token')));
            expect(art, isNot(contains('/storage/')));
          }
        }
      });

      test('album and artist container ids carry no path, token or scheme', () {
        final albumId = albumIdForTrack(jellyfin);
        final artistId = artistIdForTrack(jellyfin);

        expectSafeId(MediaId.album(albumId));
        expectSafeId(MediaId.artist(artistId));
        expectSafeId(MediaId.albumTrack(albumId, 0));
        expectSafeId(MediaId.artistTrack(artistId, 0));
      });
    });
  });
}

/// A [FakeMusicLibraryRepository] that counts catalog reads, so a test can show
/// browse stays a bounded local read and never fans out to a remote server.
class _CountingLibraryRepository extends FakeMusicLibraryRepository {
  _CountingLibraryRepository(List<Track> tracks) : super(tracks: tracks);

  int getAllTracksCalls = 0;

  @override
  Future<List<Track>> getAllTracks() {
    getAllTracksCalls++;
    return super.getAllTracks();
  }
}
