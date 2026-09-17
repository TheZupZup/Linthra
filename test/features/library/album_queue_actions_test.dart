import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/library/source_preference_controller.dart';
import 'package:linthra/features/library/widgets/collection_menu.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

/// Album queue actions (#417): Play album, Play next, Add to queue.
///
/// What every test here is really pinning down is that the queue receives the
/// album *exactly as the page shows it* (disc then track order, one entry per
/// logical song), and that it receives it in one go. The album page and the
/// Albums-tab card run the same shared command, so they cannot drift apart
/// between Android and Linux.

Track _track(
  String uri, {
  required String title,
  required String album,
  String artist = 'Daft Punk',
  int? trackNumber,
  int? discNumber,
}) =>
    Track(
      id: uri.split(':').last,
      title: title,
      uri: uri,
      artistName: artist,
      albumName: album,
      trackNumber: trackNumber,
      discNumber: discNumber,
      duration: const Duration(minutes: 3),
    );

/// An ordinary single-disc album.
final List<Track> _discovery = <Track>[
  _track('jellyfin:1', title: 'Alpha', album: 'Discovery', trackNumber: 1),
  _track('jellyfin:2', title: 'Beta', album: 'Discovery', trackNumber: 2),
  _track('jellyfin:3', title: 'Gamma', album: 'Discovery', trackNumber: 3),
];

/// A second album, used as "whatever was already playing".
final List<Track> _homework = <Track>[
  _track('jellyfin:7', title: 'One', album: 'Homework', trackNumber: 1),
  _track('jellyfin:8', title: 'Two', album: 'Homework', trackNumber: 2),
  _track('jellyfin:9', title: 'Three', album: 'Homework', trackNumber: 3),
];

/// A two-disc release the way a server reports one: track numbers restart at 1
/// on disc 2, and the catalog hands them over in no particular order.
final List<Track> _mellon = <Track>[
  _track('jellyfin:22',
      title: 'D2T2',
      album: 'Mellon Collie',
      artist: 'Smashing Pumpkins',
      discNumber: 2,
      trackNumber: 2),
  _track('jellyfin:11',
      title: 'D1T1',
      album: 'Mellon Collie',
      artist: 'Smashing Pumpkins',
      discNumber: 1,
      trackNumber: 1),
  _track('jellyfin:21',
      title: 'D2T1',
      album: 'Mellon Collie',
      artist: 'Smashing Pumpkins',
      discNumber: 2,
      trackNumber: 1),
  _track('jellyfin:12',
      title: 'D1T2',
      album: 'Mellon Collie',
      artist: 'Smashing Pumpkins',
      discNumber: 1,
      trackNumber: 2),
];

/// An album whose middle track only exists on a server: with that server away,
/// the album is still an album, just a shorter one.
final List<Track> _mixed = <Track>[
  _track('file:///music/m1.mp3',
      title: 'M1', album: 'Mixed', artist: 'Air', trackNumber: 1),
  _track('jellyfin:52',
      title: 'M2', album: 'Mixed', artist: 'Air', trackNumber: 2),
  _track('file:///music/m3.mp3',
      title: 'M3', album: 'Mixed', artist: 'Air', trackNumber: 3),
];

/// The same song on two servers, plus one that is only on the first. De-duplication
/// makes this a two-song album, not a three-row one.
final List<Track> _twin = <Track>[
  _track('jellyfin:301',
      title: 'Echo', album: 'Twin', artist: 'Boards', trackNumber: 1),
  _track('subsonic:301',
      title: 'Echo', album: 'Twin', artist: 'Boards', trackNumber: 1),
  _track('jellyfin:302',
      title: 'Foxtrot', album: 'Twin', artist: 'Boards', trackNumber: 2),
];

/// Pins the source preference so which duplicate wins never depends on an async
/// preference load landing before the assertions.
class _FixedPreference extends SourcePreferenceController {
  @override
  SourcePriority build() =>
      const SourcePriority(<String>['jellyfin', 'subsonic', 'local']);
}

/// The three actions this issue adds to album surfaces. Used by the empty-album
/// test, which runs each of them over no tracks at all.
const List<CollectionAction> _emptyAlbumActions = <CollectionAction>[
  CollectionAction.play,
  CollectionAction.playNext,
  CollectionAction.addToQueue,
];

List<String> _titles(List<Track> tracks) =>
    <String>[for (final Track t in tracks) t.title];

GoRouter _router(String initialLocation) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/album/:id',
        builder: (_, GoRouterState s) =>
            AlbumDetailScreen(albumId: s.pathParameters['id']!),
      ),
      GoRoute(path: AppRoutes.player, builder: (_, __) => const PlayerScreen()),
    ],
  );
}

Future<FakePlaybackController> _pump(
  WidgetTester tester, {
  required List<Track> tracks,
  Set<String> unavailableSourceIds = const <String>{},
  String initialLocation = AppRoutes.library,
}) async {
  final FakePlaybackController controller = FakePlaybackController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(controller),
        librarySourcePriorityProvider.overrideWith(_FixedPreference.new),
        unavailableSourceIdsProvider.overrideWithValue(unavailableSourceIds),
      ],
      child: MaterialApp.router(routerConfig: _router(initialLocation)),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _openAlbum(WidgetTester tester, String title) async {
  await tester.tap(find.text('Albums'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

/// Picks one of the two queue entries from the album header's menu.
Future<void> _headerAction(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('More album actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// The same action, reached by right-clicking the album's card in the grid.
Future<void> _cardAction(
  WidgetTester tester,
  String album,
  String label,
) async {
  await tester.tap(find.text('Albums'));
  await tester.pumpAndSettle();
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(find.text(album).first),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  group('Play album', () {
    testWidgets('starts the album in album order', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: _discovery);
      await _openAlbum(tester, 'Discovery');

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.title, 'Alpha');
      expect(_titles(controller.state.upNext), <String>['Beta', 'Gamma']);
    });

    testWidgets('replaces whatever was queued before it', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._discovery, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();

      await _openAlbum(tester, 'Discovery');
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      // Normal play semantics: the album *is* the queue now, nothing of the
      // previous one is left trailing behind it.
      expect(controller.state.currentTrack?.title, 'Alpha');
      expect(_titles(controller.state.upNext), <String>['Beta', 'Gamma']);
    });

    testWidgets('plays a multi-disc album disc by disc', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: _mellon);
      await _openAlbum(tester, 'Mellon Collie');

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      // Disc 1 end to end, then disc 2, never d1t1, d2t1, d1t2, which is what
      // ordering by track number alone produces once numbering restarts.
      expect(controller.state.currentTrack?.title, 'D1T1');
      expect(
        _titles(controller.state.upNext),
        <String>['D1T2', 'D2T1', 'D2T2'],
      );
    });
  });

  group('Play next', () {
    testWidgets('inserts the album after the current track and keeps the rest',
        (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._discovery, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();

      await _openAlbum(tester, 'Discovery');
      await _headerAction(tester, 'Play next');

      expect(controller.state.currentTrack?.title, 'One');
      expect(
        _titles(controller.state.upNext),
        <String>['Alpha', 'Beta', 'Gamma', 'Two', 'Three'],
      );
    });

    testWidgets('keeps a multi-disc album in disc order when it is inserted',
        (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._mellon, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();

      await _openAlbum(tester, 'Mellon Collie');
      await _headerAction(tester, 'Play next');

      expect(
        _titles(controller.state.upNext).take(4),
        <String>['D1T1', 'D1T2', 'D2T1', 'D2T2'],
      );
    });

    testWidgets('from silence just starts the album at its first track',
        (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: _discovery);
      await _openAlbum(tester, 'Discovery');

      await _headerAction(tester, 'Play next');

      expect(controller.state.currentTrack?.title, 'Alpha');
      expect(_titles(controller.state.upNext), <String>['Beta', 'Gamma']);
    });
  });

  group('Add to queue', () {
    testWidgets('appends the album to the end, in album order', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._discovery, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();

      await _openAlbum(tester, 'Discovery');
      await _headerAction(tester, 'Add to queue');

      expect(controller.state.currentTrack?.title, 'One');
      expect(
        _titles(controller.state.upNext),
        <String>['Two', 'Three', 'Alpha', 'Beta', 'Gamma'],
      );
    });

    testWidgets('appends the same way every time it is asked', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._discovery, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();

      await _openAlbum(tester, 'Discovery');
      await _headerAction(tester, 'Add to queue');
      await _headerAction(tester, 'Add to queue');

      // A second ask appends a second copy behind the first, in the same order:
      // the append position is the end of the queue, never a re-sort of it.
      expect(
        _titles(controller.state.upNext),
        <String>[
          'Two',
          'Three',
          'Alpha',
          'Beta',
          'Gamma',
          'Alpha',
          'Beta',
          'Gamma',
        ],
      );
    });
  });

  group('one action, one queue change', () {
    testWidgets('queues each album track exactly once', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._discovery, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();

      await _openAlbum(tester, 'Discovery');
      await _headerAction(tester, 'Add to queue');

      for (final String title in <String>['Alpha', 'Beta', 'Gamma']) {
        expect(
          _titles(controller.state.upNext).where((String t) => t == title),
          hasLength(1),
          reason: '$title should be queued exactly once',
        );
      }
    });

    testWidgets('reaches the controller once, with the whole album',
        (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._discovery, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();
      await _openAlbum(tester, 'Discovery');

      final int before = controller.emitCount;
      await _headerAction(tester, 'Add to queue');

      // One command, one queue mutation, one published state, not one of each
      // per track, which is what a per-track loop in the widget would produce.
      expect(controller.addAllToQueueCalls, hasLength(1));
      expect(_titles(controller.addAllToQueueCalls.single),
          <String>['Alpha', 'Beta', 'Gamma']);
      expect(controller.addToQueueCalls, isEmpty);
      expect(controller.emitCount - before, 1);
    });

    testWidgets('Play next reaches the controller once too', (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: <Track>[..._discovery, ..._homework]);
      await controller.playTracks(_homework);
      await tester.pumpAndSettle();
      await _openAlbum(tester, 'Discovery');

      final int before = controller.emitCount;
      await _headerAction(tester, 'Play next');

      expect(controller.playNextAllCalls, hasLength(1));
      expect(controller.playNextCalls, isEmpty);
      expect(controller.emitCount - before, 1);
    });
  });

  group('albums that are not simply three playable songs', () {
    testWidgets('an album with nothing in it offers no queue actions',
        (tester) async {
      await _pump(
        tester,
        tracks: const <Track>[],
        initialLocation: '/library/album/al-gone',
      );

      expect(find.text('Album not found'), findsOneWidget);
      expect(find.text('Play'), findsNothing);
      expect(find.byTooltip('More album actions'), findsNothing);
    });

    testWidgets('an empty set of tracks never reaches the controller',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playbackControllerProvider.overrideWithValue(controller),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (BuildContext context, WidgetRef ref, _) => Column(
                  children: <Widget>[
                    for (final CollectionAction action in _emptyAlbumActions)
                      TextButton(
                        onPressed: () => runCollectionAction(
                          context,
                          ref,
                          action,
                          const <Track>[],
                        ),
                        child: Text(action.name),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      for (final CollectionAction action in _emptyAlbumActions) {
        await tester.tap(find.text(action.name));
        await tester.pumpAndSettle();
      }

      // Nothing queued, nothing started, nothing published: an album with no
      // playable tracks is a no-op, not silence where music should be.
      expect(controller.playNextAllCalls, isEmpty);
      expect(controller.addAllToQueueCalls, isEmpty);
      expect(controller.playedTracks, isEmpty);
      expect(controller.emitCount, 0);
    });

    testWidgets('a partly unreachable album queues what can be played',
        (tester) async {
      final FakePlaybackController controller = await _pump(
        tester,
        tracks: _mixed,
        unavailableSourceIds: const <String>{'jellyfin'},
      );
      await _openAlbum(tester, 'Mixed');

      // The page shows two of the three songs, and Play queues those two, in
      // album order, with the gap simply closed rather than a dead entry left
      // in the queue.
      expect(find.text('M2'), findsNothing);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.title, 'M1');
      expect(_titles(controller.state.upNext), <String>['M3']);
    });

    testWidgets('a song held on two servers is queued once, best copy first',
        (tester) async {
      final FakePlaybackController controller =
          await _pump(tester, tracks: _twin);
      await _openAlbum(tester, 'Twin');

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      // One logical song, one queue entry: the preferred provider's copy, which
      // still carries its fallbacks through the candidate map.
      expect(controller.state.currentTrack?.uri, 'jellyfin:301');
      expect(_titles(controller.state.upNext), <String>['Foxtrot']);
      expect(controller.playedTracks.map((Track t) => t.uri),
          <String>['jellyfin:301']);
    });
  });

  group('the page and its card agree', () {
    testWidgets('Add to queue does the same thing from either surface',
        (tester) async {
      final FakePlaybackController fromCard =
          await _pump(tester, tracks: <Track>[..._mellon, ..._homework]);
      await fromCard.playTracks(_homework);
      await tester.pumpAndSettle();
      await _cardAction(tester, 'Mellon Collie', 'Add to queue');
      final List<String> viaCard = _titles(fromCard.state.upNext);

      final FakePlaybackController fromPage =
          await _pump(tester, tracks: <Track>[..._mellon, ..._homework]);
      await fromPage.playTracks(_homework);
      await tester.pumpAndSettle();
      await _openAlbum(tester, 'Mellon Collie');
      await _headerAction(tester, 'Add to queue');

      expect(_titles(fromPage.state.upNext), viaCard);
      expect(viaCard.skip(2), <String>['D1T1', 'D1T2', 'D2T1', 'D2T2']);
    });
  });
}
