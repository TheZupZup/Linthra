import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';

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
  });
}
