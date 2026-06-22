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

        expect(nodes.map((n) => n.title), ['Song a', 'Song b', 'Song c']);
        expect(nodes.map((n) => n.id), [
          MediaId.queueItem(0),
          MediaId.queueItem(1),
          MediaId.queueItem(2),
        ]);
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

        final songs = await _kids(tree, MediaId.library);
        final albums = await _kids(tree, MediaId.albums);
        final artists = await _kids(tree, MediaId.artists);

        expect(songs, hasLength(600));
        expect(albums, hasLength(groupAlbums(big).length));
        expect(artists, hasLength(groupArtists(big).length));
        // Each browse is one bounded catalog read — no per-track or remote fan-out.
        expect(repo.getAllTracksCalls, 3);
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
