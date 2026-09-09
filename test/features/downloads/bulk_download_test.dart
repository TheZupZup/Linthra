import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/bulk_download_summary.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/bulk_downloader.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/downloads/bulk_download_controller.dart';
import 'package:linthra/features/downloads/downloads_screen.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/playlists/playlist_detail_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../library/fake_remote_track_downloader.dart';
import '../player/fake_playback_controller.dart';
import 'fake_download_repository.dart';

/// Long enough for the pending futures and zero-duration timers a request goes
/// through to run, without waiting on the animations a settle would.
const Duration _tick = Duration(milliseconds: 50);

const List<Track> _remoteAlbum = <Track>[
  Track(
    id: '1',
    title: 'Alpha',
    uri: 'jellyfin:1',
    artistName: 'Daft Punk',
    albumName: 'Discovery',
    trackNumber: 1,
  ),
  Track(
    id: '2',
    title: 'Beta',
    uri: 'jellyfin:2',
    artistName: 'Daft Punk',
    albumName: 'Discovery',
    trackNumber: 2,
  ),
];

const List<Track> _localAlbum = <Track>[
  Track(
    id: '9',
    title: 'On Disk',
    uri: 'file:///music/on-disk.mp3',
    artistName: 'Local Artist',
    albumName: 'Local Album',
    trackNumber: 1,
  ),
];

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.library,
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
      GoRoute(
        path: AppRoutes.downloads,
        builder: (_, __) => const DownloadsScreen(),
      ),
      GoRoute(path: AppRoutes.player, builder: (_, __) => const PlayerScreen()),
    ],
  );
}

Future<void> _pumpAlbum(
  WidgetTester tester,
  FakeDownloadRepository repository, {
  List<Track> tracks = _remoteAlbum,
  String albumTitle = 'Discovery',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
        downloadRepositoryProvider.overrideWithValue(repository),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Albums'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(albumTitle));
  await tester.pumpAndSettle();
}

Future<void> _pumpPlaylist(
  WidgetTester tester,
  FakeDownloadRepository repository, {
  List<Track> tracks = _remoteAlbum,
}) async {
  final InMemoryPlaylistStore store = InMemoryPlaylistStore();
  await store.save(<Playlist>[
    Playlist(
      id: 'p1',
      name: 'Road Trip',
      trackIds: <String>[for (final Track track in tracks) track.uri],
    ),
  ]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playlistStoreProvider.overrideWithValue(store),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
        downloadRepositoryProvider.overrideWithValue(repository),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
      ],
      child: const MaterialApp(
        home: PlaylistDetailScreen(playlistId: 'p1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Playlist actions'));
  await tester.pumpAndSettle();
}

void main() {
  group('Album "Download all"', () {
    testWidgets('a streaming album offers the action', (tester) async {
      await _pumpAlbum(tester, FakeDownloadRepository());

      expect(find.byTooltip('Download all songs'), findsOneWidget);
    });

    testWidgets('an on-device album does not', (tester) async {
      await _pumpAlbum(
        tester,
        FakeDownloadRepository(),
        tracks: _localAlbum,
        albumTitle: 'Local Album',
      );

      // Nothing to fetch: those files are already on disk, exactly as the
      // per-track menu treats them.
      expect(find.byTooltip('Download all songs'), findsNothing);
    });

    testWidgets('it always asks first, and cancelling downloads nothing',
        (tester) async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      await _pumpAlbum(tester, repository);

      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();

      // The count is named, so a bulk download is never a surprise.
      expect(
        find.textContaining('Make all 2 songs from “Discovery” available '
            'offline?'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repository.requested, isEmpty);
    });

    testWidgets('confirming downloads every track and reports the result',
        (tester) async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      await _pumpAlbum(tester, repository);

      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      expect(repository.requested, <String>['jellyfin:1', 'jellyfin:2']);
      expect(
        find.text('All 2 songs from “Discovery” are available offline.'),
        findsOneWidget,
      );
    });

    testWidgets('a cache that cannot fit the album says so, not nothing',
        (tester) async {
      final FakeDownloadRepository repository =
          FakeDownloadRepository(outOfSpaceAfter: 0);
      await _pumpAlbum(tester, repository);

      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      // Refused by the cache, and named as such rather than left to look like
      // an unexplained failure.
      expect(
        find.textContaining('too large for the cache limit'),
        findsOneWidget,
      );
    });

    testWidgets('a batch that cannot run says so and leaves the app usable',
        (tester) async {
      final FakeDownloadRepository repository =
          FakeDownloadRepository(failDownloadedKeys: true);
      await _pumpAlbum(tester, repository);

      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't start that download. Try again in a moment."),
        findsOneWidget,
      );

      // Not left stuck "busy": asking again offers the confirmation, not the
      // "another download is running" refusal.
      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Make all 2 songs from “Discovery” available '
            'offline?'),
        findsOneWidget,
      );
    });

    testWidgets('a Wi-Fi-only device is told why the album is queued',
        (tester) async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        outcomes: <String, DownloadRequestOutcome>{
          'jellyfin:1': DownloadRequestOutcome.waitingForWifi,
          'jellyfin:2': DownloadRequestOutcome.waitingForWifi,
        },
      );
      await _pumpAlbum(tester, repository);

      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Downloads are limited to Wi-Fi'),
        findsOneWidget,
      );
    });
  });

  group('Playlist "Download all"', () {
    testWidgets('downloads every song in the playlist once confirmed',
        (tester) async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      await _pumpPlaylist(tester, repository);

      await tester.tap(find.text('Download all'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Make all 2 songs from “Road Trip” available '
            'offline?'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      expect(repository.requested, <String>['jellyfin:1', 'jellyfin:2']);
    });

    testWidgets('an all-local playlist is not offered the action',
        (tester) async {
      await _pumpPlaylist(
        tester,
        FakeDownloadRepository(),
        tracks: _localAlbum,
      );

      expect(find.text('Download all'), findsNothing);
      // The rest of the playlist menu is untouched.
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete playlist'), findsOneWidget);
    });
  });

  group('Counting what the user is shown', () {
    testWidgets('a duplicated song is confirmed and reported once',
        (tester) async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      await _pumpPlaylist(
        tester,
        repository,
        // The same song twice, as a hand-built playlist can easily hold.
        tracks: <Track>[_remoteAlbum[0], _remoteAlbum[1], _remoteAlbum[0]],
      );

      await tester.tap(find.text('Download all'));
      await tester.pumpAndSettle();

      // Two, not three: the number confirmed is the number that gets requested,
      // so the closing line cannot disagree with it.
      expect(
        find.textContaining('Make all 2 songs from “Road Trip” available '
            'offline?'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      expect(repository.requested, <String>['jellyfin:1', 'jellyfin:2']);
      expect(
        find.text('All 2 songs from “Road Trip” are available offline.'),
        findsOneWidget,
      );
    });

    testWidgets('a mixed collection downloads only what streams',
        (tester) async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      await _pumpPlaylist(
        tester,
        repository,
        tracks: <Track>[_remoteAlbum[0], ..._localAlbum],
      );

      await tester.tap(find.text('Download all'));
      await tester.pumpAndSettle();

      // The on-device file is not part of the batch, so it is not counted.
      expect(
        find.textContaining('Make 1 song from “Road Trip” available offline?'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      // Its bytes are already on disk, and its row deliberately offers no
      // offline action, so it never becomes a download.
      expect(repository.requested, <String>['jellyfin:1']);
    });

    testWidgets('songs already offline are not announced as downloads',
        (tester) async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        alreadyDownloaded: <String>{
          CachedTrack.cacheKeyForTrack(_remoteAlbum[0]),
        },
      );
      await _pumpAlbum(tester, repository);

      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();

      // The collection is 2 songs and the wording is about making it available,
      // not about downloading 2, because only 1 will actually be fetched.
      expect(
        find.textContaining('Make all 2 songs from “Discovery” available '
            'offline?'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pumpAndSettle();

      expect(repository.requested, <String>['jellyfin:2']);
      expect(
        find.text('All 2 songs from “Discovery” are available offline.'),
        findsOneWidget,
      );
    });

    test('two starts in the same turn run one batch', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          downloadRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      final BulkDownloadController controller =
          container.read(bulkDownloadControllerProvider.notifier);

      // Both calls are made before either has published "running", which is the
      // window a state-only guard would let a second batch through.
      final Future<BulkDownloadSummary?> first =
          controller.start(label: 'Discovery', tracks: _remoteAlbum);
      final Future<BulkDownloadSummary?> second =
          controller.start(label: 'Discovery', tracks: _remoteAlbum);

      expect(await first, isNotNull);
      expect(await second, isNull);
      // Requested once each, not twice.
      expect(repository.requested, <String>['jellyfin:1', 'jellyfin:2']);
    });
  });

  group('Downloads screen batch progress', () {
    testWidgets('shows the running batch and stops it on demand',
        (tester) async {
      final Completer<void> hold = Completer<void>();
      final FakeDownloadRepository repository =
          FakeDownloadRepository(hold: hold);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          musicLibraryRepositoryProvider.overrideWithValue(
            FakeMusicLibraryRepository(tracks: _remoteAlbum),
          ),
          downloadRepositoryProvider.overrideWithValue(repository),
          // One outstanding request at a time, so the held request is the only
          // one in flight and the stop is unambiguous.
          bulkDownloaderProvider
              .overrideWithValue(const BulkDownloader(maxOutstanding: 1)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DownloadsScreen()),
        ),
      );
      await tester.pump(_tick);

      final Future<BulkDownloadSummary?> batch =
          container.read(bulkDownloadControllerProvider.notifier).start(
                label: 'Discovery',
                tracks: _remoteAlbum,
              );
      await tester.pump(_tick);
      await tester.pump(_tick);

      expect(find.textContaining('Downloading “Discovery”'), findsOneWidget);

      await tester.tap(find.text('Stop'));
      await tester.pump(_tick);

      hold.complete();
      final BulkDownloadSummary? summary = await batch;
      await tester.pump(_tick);

      expect(summary?.canceled, isTrue);
      // Stopped after the one request that was already in flight; nothing was
      // removed, so what did download stays downloaded.
      expect(repository.requested, <String>['jellyfin:1']);
      expect(repository.removed, isEmpty);
      // The banner belongs to a running batch only.
      expect(find.text('Stop'), findsNothing);
    });

    testWidgets('a second batch is refused while one is running',
        (tester) async {
      final Completer<void> hold = Completer<void>();
      final FakeDownloadRepository repository =
          FakeDownloadRepository(hold: hold);
      await _pumpAlbum(tester, repository);

      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pump(_tick);
      await tester.pump(_tick);

      // The first batch is still held; asking again must not start a second.
      await tester.tap(find.byTooltip('Download all songs'));
      await tester.pump(_tick);

      expect(find.textContaining('Another download is still running'),
          findsOneWidget);
      // The two tracks were requested once, by the first batch: no second run
      // was started behind it.
      expect(repository.requested, <String>['jellyfin:1', 'jellyfin:2']);

      hold.complete();
      await tester.pump(_tick);
      await tester.pump(_tick);
    });
  });
}
