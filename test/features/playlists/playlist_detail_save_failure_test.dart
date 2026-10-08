// What the playlist screen does when the device refuses to save an edit
// (#808): the listener is told where they made it, the screen doesn't act as
// if it had worked, and nothing it does once the save comes back lands on a
// route it didn't open.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/synced_playlist_repository.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/playlists/playlist_detail_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
  Track(id: 'c', title: 'Song C', uri: 'file:///c.mp3'),
];

const String _refused = "Couldn't save that playlist change";

/// A disk that can fill up, and whose next save can be held until the test
/// says whether it was written.
class _DiskStore extends InMemoryPlaylistStore {
  bool refuse = false;

  /// How many more saves go through before the disk is full.
  int? savesLeft;
  Completer<bool>? _held;

  void holdNextSave() => _held = Completer<bool>();

  void releaseHeld({required bool written}) {
    final Completer<bool> held = _held!;
    _held = null;
    held.complete(written);
  }

  @override
  Future<void> save(List<Playlist> playlists) async {
    final int? left = savesLeft;
    if (left != null) {
      if (left == 0) refuse = true;
      savesLeft = left - 1;
    }
    bool written = !refuse;
    final Completer<bool>? held = _held;
    if (held != null) written = await held.future;
    if (!written) {
      throw const LocalStoreWriteException(LocalStoreArea.playlists);
    }
    return super.save(playlists);
  }
}

/// A server whose deletes take as long as the test says.
class _SlowDeletes implements RemotePlaylistGateway {
  final Completer<void> deleteLands = Completer<void>();
  bool deleted = false;

  @override
  PlaylistSource get source => PlaylistSource.subsonic;
  @override
  bool get isConnected => true;
  @override
  bool get pushesRename => true;
  @override
  bool get pushesReorder => true;
  @override
  Future<RemotePlaylistListing> fetchPlaylists() async =>
      const RemotePlaylistListing(<RemotePlaylistData>[]);
  @override
  Future<String> createRemotePlaylist(String name, List<String> uris) async =>
      'srv';
  @override
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  }) async {}
  @override
  Future<void> renameRemote(String remoteId, String name) async {}
  @override
  Future<void> deleteRemote(String remoteId) async {
    await deleteLands.future;
    deleted = true;
  }
}

void main() {
  late _DiskStore store;
  late GoRouter router;

  Future<void> pump(
    WidgetTester tester, {
    List<Playlist> playlists = const <Playlist>[
      Playlist(
        id: 'p1',
        name: 'Road Trip',
        trackIds: <String>['file:///a.mp3', 'file:///b.mp3', 'file:///c.mp3'],
      ),
    ],
    RemotePlaylistGateway? gateway,
  }) async {
    store = _DiskStore();
    await store.save(playlists);
    router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (BuildContext context, __) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/p1'),
              child: const Text('Playlists tab'),
            ),
          ),
        ),
        GoRoute(
          path: '/p1',
          builder: (_, __) => const PlaylistDetailScreen(playlistId: 'p1'),
        ),
        GoRoute(
          path: AppRoutes.player,
          builder: (_, __) => const Scaffold(body: Text('player-screen')),
        ),
      ],
    );
    addTearDown(router.dispose);
    final FakePlaybackController controller = FakePlaybackController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playlistStoreProvider.overrideWithValue(store),
          if (gateway != null)
            playlistRepositoryProvider.overrideWith((ref) {
              final SyncedPlaylistRepository repository =
                  SyncedPlaylistRepository(
                store: store,
                gateways: <RemotePlaylistGateway>[gateway],
              );
              ref.onDispose(repository.dispose);
              return repository;
            }),
          musicLibraryRepositoryProvider
              .overrideWithValue(FakeMusicLibraryRepository(tracks: _tracks)),
          playbackControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists tab'));
    await tester.pumpAndSettle();
    expect(find.text('Road Trip'), findsOneWidget);
  }

  /// Opens the menu and confirms the delete, leaving whatever the save does
  /// to the test.
  Future<void> confirmDelete(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Playlist actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
  }

  group('deleting from the playlist (#808)', () {
    testWidgets('a delete the device refuses stays on the playlist and says so',
        (WidgetTester tester) async {
      await pump(tester);
      store.refuse = true;

      await confirmDelete(tester);
      await tester.pumpAndSettle();

      expect(find.text('Road Trip'), findsOneWidget);
      expect(find.text('Playlists tab'), findsNothing);
      expect(find.textContaining(_refused), findsOneWidget);
      expect(await store.load(), hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a delete that saves closes the playlist', (tester) async {
      await pump(tester);

      await confirmDelete(tester);
      await tester.pumpAndSettle();

      expect(find.text('Playlists tab'), findsOneWidget);
      expect(find.textContaining(_refused), findsNothing);
      expect(await store.load(), isEmpty);
    });

    testWidgets('the playlist stays open until the delete has saved',
        (tester) async {
      await pump(tester);
      store.holdNextSave();

      await confirmDelete(tester);
      await tester.pumpAndSettle();
      expect(find.text('Road Trip'), findsOneWidget);

      store.releaseHeld(written: true);
      await tester.pumpAndSettle();
      expect(find.text('Playlists tab'), findsOneWidget);
    });

    testWidgets('a page opened over it while the delete saves stays open',
        (tester) async {
      await pump(tester);
      store.holdNextSave();

      await confirmDelete(tester);
      await tester.pumpAndSettle();
      unawaited(router.push(AppRoutes.player));
      await tester.pumpAndSettle();
      expect(find.text('player-screen'), findsOneWidget);

      store.releaseHeld(written: true);
      await tester.pumpAndSettle();

      expect(find.text('player-screen'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(await store.load(), isEmpty);
    });

    testWidgets('going back while a refused delete saves closes nothing more',
        (tester) async {
      await pump(tester);
      store.holdNextSave();

      await confirmDelete(tester);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Playlists tab'), findsOneWidget);

      store.releaseHeld(written: false);
      await tester.pumpAndSettle();

      expect(find.text('Playlists tab'), findsOneWidget);
      expect(find.textContaining(_refused), findsOneWidget);
      expect(await store.load(), hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a synced playlist closes once deleted here, not on its server',
        (tester) async {
      final _SlowDeletes server = _SlowDeletes();
      await pump(
        tester,
        playlists: const <Playlist>[
          Playlist(
            id: 'p1',
            name: 'Road Trip',
            source: PlaylistSource.subsonic,
            remoteId: 'srv-1',
            trackIds: <String>['file:///a.mp3'],
            syncState: PlaylistSyncState.synced,
          ),
        ],
        gateway: server,
      );

      await confirmDelete(tester);
      await tester.pumpAndSettle();

      expect(find.text('Playlists tab'), findsOneWidget);
      expect(server.deleted, isFalse);
      server.deleteLands.complete();
      await tester.pumpAndSettle();
      expect(server.deleted, isTrue);
    });
  });

  group('a keyboard move the device refuses (#808)', () {
    Finder handles() => find.byIcon(Icons.drag_handle);

    bool focused(WidgetTester tester, int row) =>
        Focus.of(tester.element(handles().at(row))).hasFocus;

    Future<void> focusRow(WidgetTester tester, int row) async {
      Focus.of(tester.element(handles().at(row))).requestFocus();
      await tester.pumpAndSettle();
    }

    Future<void> moveDown(WidgetTester tester, {int repeats = 0}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      for (int i = 0; i < repeats; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    Future<List<String>> stored() async => (await store.load()).single.trackIds;

    testWidgets('leaves focus on the song that did not move', (tester) async {
      await pump(tester);
      await focusRow(tester, 0);
      store.refuse = true;

      await moveDown(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining(_refused), findsOneWidget);
      expect(await stored(), <String>[
        'file:///a.mp3',
        'file:///b.mp3',
        'file:///c.mp3',
      ]);
      // Song A is still on the first row, and focus is still on it.
      expect(focused(tester, 0), isTrue);
      expect(focused(tester, 1), isFalse);
    });

    testWidgets('a held move after a refused one still moves the same song',
        (tester) async {
      await pump(tester);
      await focusRow(tester, 0);
      store.holdNextSave();

      // Two steps down for Song A; the second is sent while the first is
      // still saving, from where the first would have put it.
      await moveDown(tester, repeats: 1);
      store.releaseHeld(written: false);
      await tester.pumpAndSettle();

      expect(find.textContaining(_refused), findsOneWidget);
      // Song A moved, never Song B: the second step put it where both
      // steps were taking it.
      expect(await stored(), <String>[
        'file:///b.mp3',
        'file:///c.mp3',
        'file:///a.mp3',
      ]);
      // And focus went with it.
      expect(focused(tester, 2), isTrue);
    });
  });

  testWidgets('removing several songs that stops partway says what is left',
      (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove from playlist'));
    await tester.pumpAndSettle();
    // Song A's removal saves; Song B's doesn't.
    store.savesLeft = 1;
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(
        find.textContaining("Couldn't save the other removal"), findsOneWidget);
    expect(find.textContaining('Removed 2 songs'), findsNothing);
    expect((await store.load()).single.trackIds, <String>[
      'file:///b.mp3',
      'file:///c.mp3',
    ]);
    expect(tester.takeException(), isNull);
  });
}
