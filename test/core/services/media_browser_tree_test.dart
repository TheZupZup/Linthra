import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import 'fake_browse_repositories.dart';

Track _track(String id, {String? artist, String? album}) {
  return Track(
    id: id,
    title: 'Song $id',
    uri: '/$id.mp3',
    artistName: artist,
    albumName: album,
  );
}

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

    group('childrenOf', () {
      test('root lists Library and Queue as browsable categories', () async {
        final nodes =
            await treeOf(library).childrenOf(MediaId.root, PlaybackState.idle);

        expect(nodes.map((n) => n.id), [MediaId.library, MediaId.queue]);
        expect(nodes.map((n) => n.title), ['Library', 'Queue']);
        expect(nodes.every((n) => n.playable), isFalse);
      });

      test('library exposes every catalog track as a playable leaf', () async {
        final nodes = await treeOf(library)
            .childrenOf(MediaId.library, PlaybackState.idle);

        expect(nodes.map((n) => n.id), [
          MediaId.libraryTrack('a'),
          MediaId.libraryTrack('b'),
          MediaId.libraryTrack('c'),
        ]);
        expect(nodes.every((n) => n.playable), isTrue);
        expect(nodes.first.track, library.first);
      });

      test('library track subtitle joins the present artist/album parts',
          () async {
        final nodes = await treeOf(library)
            .childrenOf(MediaId.library, PlaybackState.idle);

        expect(nodes[0].subtitle, 'Artist a • Album a');
        expect(nodes[1].subtitle, 'Artist b');
        expect(nodes[2].subtitle, isNull);
      });

      test('empty library yields no track nodes', () async {
        final nodes = await treeOf(const <Track>[])
            .childrenOf(MediaId.library, PlaybackState.idle);

        expect(nodes, isEmpty);
      });

      test('queue lists the current track followed by up-next', () async {
        final playback = _playing(library[0], upNext: [library[1], library[2]]);

        final nodes = await treeOf(library).childrenOf(MediaId.queue, playback);

        expect(nodes.map((n) => n.title), ['Song a', 'Song b', 'Song c']);
        expect(nodes.map((n) => n.id), [
          MediaId.queueItem(0),
          MediaId.queueItem(1),
          MediaId.queueItem(2),
        ]);
      });

      test('queue is empty when nothing is playing', () async {
        final nodes =
            await treeOf(library).childrenOf(MediaId.queue, PlaybackState.idle);

        expect(nodes, isEmpty);
      });

      test('an unknown parent id yields an empty list', () async {
        final nodes =
            await treeOf(library).childrenOf('nonsense', PlaybackState.idle);

        expect(nodes, isEmpty);
      });
    });

    group('resolve', () {
      test('a library track resolves to the whole catalog at its index',
          () async {
        final request = await treeOf(library)
            .resolve(MediaId.libraryTrack('b'), PlaybackState.idle);

        expect(request, isNotNull);
        expect(request!.tracks, library);
        expect(request.startIndex, 1);
      });

      test('a missing library track resolves to null', () async {
        final request = await treeOf(library)
            .resolve(MediaId.libraryTrack('zzz'), PlaybackState.idle);

        expect(request, isNull);
      });

      test('a queue item resolves to the live queue at its index', () async {
        final playback = _playing(library[0], upNext: [library[1], library[2]]);

        final request =
            await treeOf(library).resolve(MediaId.queueItem(2), playback);

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['a', 'b', 'c']);
        expect(request.startIndex, 2);
      });

      test('an out-of-range queue index resolves to null', () async {
        final playback = _playing(library[0]);

        final request =
            await treeOf(library).resolve(MediaId.queueItem(5), playback);

        expect(request, isNull);
      });

      test('a non-numeric queue id resolves to null', () async {
        final request = await treeOf(library)
            .resolve('queue/not-a-number', PlaybackState.idle);

        expect(request, isNull);
      });

      test('a category id is not playable', () async {
        expect(
          await treeOf(library).resolve(MediaId.library, PlaybackState.idle),
          isNull,
        );
        expect(
          await treeOf(library).resolve(MediaId.root, PlaybackState.idle),
          isNull,
        );
      });
    });

    group('root categories', () {
      MediaBrowserTree treeWith({
        List<Playlist> playlists = const <Playlist>[],
        Set<String> favorites = const <String>{},
      }) {
        return MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: library),
          playlists: FakePlaylistRepository(playlists),
          favorites: FakeFavoritesRepository(favorites),
        );
      }

      test('only Library and Queue without playlist/favorites', () async {
        final nodes = await _kids(treeOf(library), MediaId.root);

        expect(nodes.map((n) => n.id), [MediaId.library, MediaId.queue]);
      });

      test('Playlists node appears only when a playlist exists', () async {
        final without = await _kids(treeWith(), MediaId.root);
        expect(without.map((n) => n.id), isNot(contains(MediaId.playlists)));

        final tree = treeWith(
          playlists: [const Playlist(id: 'p1', name: 'Roadtrip')],
        );
        final nodes = await _kids(tree, MediaId.root);
        expect(nodes.map((n) => n.id), contains(MediaId.playlists));
      });

      test('Favorites node appears only when a favourite exists', () async {
        final without = await _kids(treeWith(), MediaId.root);
        expect(without.map((n) => n.id), isNot(contains(MediaId.favorites)));

        final tree = treeWith(favorites: {'a'});
        final nodes = await _kids(tree, MediaId.root);
        expect(nodes.map((n) => n.id), contains(MediaId.favorites));
      });

      test('all four categories show when both exist', () async {
        final tree = treeWith(
          playlists: [const Playlist(id: 'p1', name: 'Roadtrip')],
          favorites: {'a'},
        );

        final nodes = await _kids(tree, MediaId.root);

        expect(nodes.map((n) => n.id), [
          MediaId.library,
          MediaId.queue,
          MediaId.playlists,
          MediaId.favorites,
        ]);
        expect(nodes.every((n) => n.playable), isFalse);
      });

      test('browses from cold repositories before any UI', () async {
        // Depends only on repositories and a PlaybackState snapshot, never on a
        // widget, so Android Auto can load it the moment the service starts.
        final tree = treeWith(
          playlists: [const Playlist(id: 'p1', name: 'Roadtrip')],
          favorites: {'a'},
        );

        final root = await _kids(tree, MediaId.root);
        final lib = await _kids(tree, MediaId.library);

        expect(root, isNotEmpty);
        expect(root.map((n) => n.id), contains(MediaId.library));
        expect(lib, isNotEmpty);
      });
    });

    group('playlists', () {
      final playlists = <Playlist>[
        // 'x' is not in the catalog and must be dropped (it can't be played).
        const Playlist(id: 'p1', name: 'Roadtrip', trackIds: ['c', 'a', 'x']),
        const Playlist(id: 'p2', name: 'Empty'),
      ];

      MediaBrowserTree buildTree() {
        return MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: library),
          playlists: FakePlaylistRepository(playlists),
        );
      }

      test('lists each playlist as a browsable category', () async {
        final nodes = await _kids(buildTree(), MediaId.playlists);

        expect(nodes.map((n) => n.id), [
          MediaId.playlist('p1'),
          MediaId.playlist('p2'),
        ]);
        expect(nodes.map((n) => n.title), ['Roadtrip', 'Empty']);
        // The subtitle is the playlist's declared track count (3 for p1,
        // including 'x'); opening it then lists only the 2 catalog-resolved
        // tracks — see the next test.
        expect(nodes.map((n) => n.subtitle), ['3 tracks', '0 tracks']);
        expect(nodes.every((n) => n.playable), isFalse);
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
        final nodes = await _kids(buildTree(), MediaId.playlist('p2'));

        expect(nodes, isEmpty);
      });

      test('a playlist track resolves to the playlist at its index', () async {
        final id = MediaId.playlistTrack('p1', 1);
        final request = await _pick(buildTree(), id);

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['c', 'a']);
        expect(request.startIndex, 1);
      });

      test('an out-of-range playlist index resolves to null', () async {
        final id = MediaId.playlistTrack('p1', 9);
        final request = await _pick(buildTree(), id);

        expect(request, isNull);
      });

      test('an unknown playlist id is safe', () async {
        final id = MediaId.playlistTrack('nope', 0);
        expect(await _pick(buildTree(), id), isNull);
        expect(await _kids(buildTree(), MediaId.playlist('nope')), isEmpty);
      });
    });

    group('favorites', () {
      // Catalog order is a, b, c; favouriting a and c (plus a stale 'x' not in
      // the catalog) must list/resolve as [a, c] in catalog order.
      MediaBrowserTree buildTree() {
        return MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: library),
          favorites: FakeFavoritesRepository({'a', 'c', 'x'}),
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

      test('a favourite resolves to the favourites at its index', () async {
        final request = await _pick(buildTree(), MediaId.favoriteItem(1));

        expect(request, isNotNull);
        expect(request!.tracks.map((t) => t.id), ['a', 'c']);
        expect(request.startIndex, 1);
      });

      test('an out-of-range favourite index resolves to null', () async {
        final request = await _pick(buildTree(), MediaId.favoriteItem(9));

        expect(request, isNull);
      });
    });

    group('safe media ids', () {
      final jellyfin = Track(
        id: 'jf-guid-123',
        title: 'Remote Song',
        uri: 'jellyfin:jf-guid-123',
        artistName: 'Remote Artist',
        artworkUri: Uri.parse(
          'https://music.example.com/Items/jf-guid-123/Images/Primary',
        ),
      );
      const localTrack = Track(
        id: 'local-1',
        title: 'Local Song',
        uri: '/storage/music/local.mp3',
      );

      test('local and Jellyfin both map to token-free leaves', () async {
        final tree = MediaBrowserTree(
          FakeMusicLibraryRepository(tracks: <Track>[jellyfin, localTrack]),
        );
        final nodes = await _kids(tree, MediaId.library);

        expect(nodes.map((n) => n.id), [
          MediaId.libraryTrack('jf-guid-123'),
          MediaId.libraryTrack('local-1'),
        ]);
        expect(nodes.every((n) => n.id.isNotEmpty), isTrue);
        expect(nodes.every((n) => n.title.isNotEmpty), isTrue);
        expect(nodes.every((n) => n.playable), isTrue);

        // No id leaks a token, an auth query, a URI scheme, or a stream URL.
        for (final node in nodes) {
          expect(node.id, isNot(contains('api_key')));
          expect(node.id, isNot(contains('token')));
          expect(node.id, isNot(contains('jellyfin:')));
          expect(node.id, isNot(contains('://')));
        }
      });
    });
  });
}
