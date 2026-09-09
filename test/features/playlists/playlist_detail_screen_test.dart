import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/playlists/playlist_detail_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
  Track(id: 'c', title: 'Song C', uri: 'file:///c.mp3'),
];

GoRouter _router() {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, __) => const PlaylistDetailScreen(playlistId: 'p1'),
      ),
      GoRoute(
        path: AppRoutes.player,
        builder: (_, __) => const Scaffold(body: Text('player-screen')),
      ),
    ],
  );
}

/// A playlist long enough to scroll, as in the report behind #582.
final List<Track> _long = <Track>[
  for (int i = 0; i < 60; i++)
    Track(
      id: 'song-$i',
      title: 'Song ${i.toString().padLeft(2, '0')}',
      uri: 'file:///song-$i.mp3',
    ),
];

Future<void> _pump(
  WidgetTester tester, {
  required InMemoryPlaylistStore store,
  required FakePlaybackController controller,
  List<Track> tracks = _tracks,
  TargetPlatform? platform,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playlistStoreProvider.overrideWithValue(store),
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: tracks)),
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp.router(
        theme: platform == null ? null : ThemeData(platform: platform),
        routerConfig: _router(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<InMemoryPlaylistStore> _seededStore({
  List<String> trackIds = const <String>['file:///a.mp3', 'file:///b.mp3'],
}) async {
  final InMemoryPlaylistStore store = InMemoryPlaylistStore();
  await store.save(<Playlist>[
    Playlist(id: 'p1', name: 'Road Trip', trackIds: trackIds),
  ]);
  return store;
}

/// Drags the track row at [from] by its handle past the end of the list.
///
/// Overshoots deliberately — the drop index clamps to the last slot — so the
/// gesture reads as "drag it to the bottom" and does not depend on row metrics.
Future<void> _dragToEnd(WidgetTester tester, {required int from}) async {
  final Finder handles = find.byIcon(Icons.drag_handle);
  final int rows = handles.evaluate().length;
  final double rowHeight =
      tester.getCenter(handles.at(1)).dy - tester.getCenter(handles.at(0)).dy;
  final double travel = rowHeight * (rows + 1);
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(handles.at(from)));
  // Start moving promptly. Holding still past the long-press timeout hands the
  // gesture to the row's selection-mode recognizer, and the drag never happens.
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Gives the reorder handle on row [index] keyboard focus, the way Tab would.
Future<void> _focusHandle(WidgetTester tester, int index) async {
  final Finder handles = find.byIcon(Icons.drag_handle);
  Focus.of(tester.element(handles.at(index))).requestFocus();
  await tester.pumpAndSettle();
}

/// Presses Ctrl + Arrow Up/Down, the chord that moves the focused row.
Future<void> _pressMoveChord(WidgetTester tester, {required bool down}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(
    down ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowUp,
  );
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// Holds Ctrl + Arrow Down for [repeats] extra auto-repeats, with no frame in
/// between.
///
/// A playlist edit reaches the screen through the store's stream and an async
/// re-resolve, so nothing has rebuilt the rows by the time the repeat arrives.
/// This is the real shape of a held key, and the one case a press-then-pump
/// test cannot reach.
Future<void> _holdMoveChordDown(WidgetTester tester, {int repeats = 1}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
  for (int i = 0; i < repeats; i++) {
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// The stored track order, read back from the playlist store.
Future<List<String>> _storedOrder(InMemoryPlaylistStore store) async {
  final List<Playlist> saved = await store.load();
  return saved.single.trackIds;
}

/// The custom semantics actions offered on the row rendering [title].
Set<String> _customActionsOn(WidgetTester tester, String title) {
  return tester
      .getSemantics(find.text(title))
      .getSemanticsData()
      .customSemanticsActionIds!
      .map((int id) => CustomSemanticsAction.getAction(id)!.label!)
      .toSet();
}

void main() {
  testWidgets('entering selection keeps the playlist where it was (#582)',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _long) track.uri],
    );
    await _pump(
      tester,
      store: store,
      controller: FakePlaybackController(),
      tracks: _long,
    );

    final Finder scrollable = find.byType(Scrollable).last;
    await tester.drag(scrollable, const Offset(0, -900));
    await tester.pumpAndSettle();
    final double before =
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0), reason: 'the drag should have scrolled');

    // Long-press a visible row to enter selection. The list widget changes
    // here (no drag handles while selecting), so the offset has to be carried
    // across rather than kept in one Scrollable.
    await tester.longPress(find.byType(ListTile).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    final Finder selectionScrollable = find.byType(Scrollable).last;
    expect(
      tester.state<ScrollableState>(selectionScrollable).position.pixels,
      before,
    );
  });

  testWidgets('renders the playlist tracks', (tester) async {
    await _pump(
      tester,
      store: await _seededStore(),
      controller: FakePlaybackController(),
    );
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
  });

  testWidgets('dragging a track to the end persists the new order',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>['file:///a.mp3', 'file:///b.mp3', 'file:///c.mp3'],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    // The screen converts between the reorder callback's destination index and
    // the pre-removal index the repository normalises from. The two conversions
    // cancel out, so only an end-to-end drag proves the pair is still in step:
    // dropping either one silently files the track one slot off.
    await _dragToEnd(tester, from: 0);

    final List<Playlist> saved = await store.load();
    expect(
      saved.single.trackIds,
      <String>['file:///b.mp3', 'file:///c.mp3', 'file:///a.mp3'],
    );
  });

  testWidgets('Play queues the playlist and opens the player', (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.first.id, 'a');
    // The rest of the playlist is queued behind the first track.
    expect(controller.state.upNext.map((Track t) => t.id), <String>['b']);
    expect(find.text('player-screen'), findsOneWidget);
  });

  testWidgets('tapping a track plays from there and queues the playlist',
      (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();

    expect(controller.playedTracks.first.id, 'b');
    expect(find.text('player-screen'), findsOneWidget);
  });

  testWidgets(
      'track row menu toggles favorite without playing or changing the queue',
      (tester) async {
    final FakePlaybackController controller = FakePlaybackController();
    await _pump(tester, store: await _seededStore(), controller: controller);

    await tester.tap(find.byTooltip('Track actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Add to favorites'), findsOneWidget);

    await tester.tap(find.text('Add to favorites'));
    await tester.pumpAndSettle();

    // Favoriting is a pure like: no playback, no queue change.
    expect(controller.playedTracks, isEmpty);
    expect(controller.state.upNext, isEmpty);

    // Reopening the row's menu now offers the filled-heart remove action.
    await tester.tap(find.byTooltip('Track actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove from favorites'), findsOneWidget);
  });

  testWidgets('long-press enters selection mode and shows the count',
      (tester) async {
    await _pump(
      tester,
      store: await _seededStore(),
      controller: FakePlaybackController(),
    );

    await tester.longPress(find.text('Song A'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // Selecting another track updates the count.
    await tester.tap(find.text('Song B'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('Ctrl+Arrow moves the focused track without a pointer',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>['file:///a.mp3', 'file:///b.mp3', 'file:///c.mp3'],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    await _focusHandle(tester, 0);
    await _pressMoveChord(tester, down: true);

    expect(
      await _storedOrder(store),
      <String>['file:///b.mp3', 'file:///a.mp3', 'file:///c.mp3'],
    );
  });

  testWidgets('Ctrl+Arrow up walks a track back to the top', (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>['file:///a.mp3', 'file:///b.mp3', 'file:///c.mp3'],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    // Focus follows the moved track, so the chord can be pressed twice in a
    // row without re-aiming at it.
    await _focusHandle(tester, 2);
    await _pressMoveChord(tester, down: false);
    await _pressMoveChord(tester, down: false);

    expect(
      await _storedOrder(store),
      <String>['file:///c.mp3', 'file:///a.mp3', 'file:///b.mp3'],
    );
  });

  testWidgets('a move chord at either end of the playlist is a no-op',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>['file:///a.mp3', 'file:///b.mp3'],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    await _focusHandle(tester, 0);
    await _pressMoveChord(tester, down: false);
    await _focusHandle(tester, 1);
    await _pressMoveChord(tester, down: true);

    expect(
      await _storedOrder(store),
      <String>['file:///a.mp3', 'file:///b.mp3'],
    );
  });

  testWidgets('a held chord keeps walking the same track', (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _tracks) track.uri],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    await _focusHandle(tester, 0);
    // Two presses, no frame in between. Reading the source index off the handle
    // that fired would apply the second move to the order the first one already
    // changed, and land Song A back where it started.
    await _holdMoveChordDown(tester);

    expect(
      await _storedOrder(store),
      <String>['file:///b.mp3', 'file:///c.mp3', 'file:///a.mp3'],
    );
  });

  testWidgets('a chord after a pointer drag moves the track that was dragged',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _tracks) track.uri],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    // Focus row 0 (Song A), then drag it to the end. Focus is per position, so
    // without the remap the next chord would move whatever slid into row 0.
    await _focusHandle(tester, 0);
    await _dragToEnd(tester, from: 0);
    await _pressMoveChord(tester, down: false);

    expect(
      await _storedOrder(store),
      <String>['file:///b.mp3', 'file:///a.mp3', 'file:///c.mp3'],
    );
  });

  testWidgets('a mouse drag alone never pulls focus into the playlist',
      (tester) async {
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _tracks) track.uri],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    await _dragToEnd(tester, from: 0);
    await _pressMoveChord(tester, down: true);

    // The drag landed; the chord that followed had nothing focused to move.
    expect(
      await _storedOrder(store),
      <String>['file:///b.mp3', 'file:///c.mp3', 'file:///a.mp3'],
    );
  });

  testWidgets('rows offer move actions, and only the ones that exist',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _tracks) track.uri],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    // A screen reader gets the same two moves the keyboard chord does.
    expect(
      _customActionsOn(tester, 'Song B'),
      <String>{'Move up', 'Move down'},
    );
    // The ends of the list only offer the move that goes somewhere.
    expect(_customActionsOn(tester, 'Song A'), <String>{'Move down'});
    expect(_customActionsOn(tester, 'Song C'), <String>{'Move up'});

    handle.dispose();
  });

  testWidgets('the drag handle answers a screen reader move', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _tracks) track.uri],
    );
    await _pump(tester, store: store, controller: FakePlaybackController());

    final int moveDown = tester
        .getSemantics(find.text('Song A'))
        .getSemanticsData()
        .customSemanticsActionIds!
        .firstWhere(
          (int id) => CustomSemanticsAction.getAction(id)!.label == 'Move down',
        );
    tester.semantics.performAction(
      find.semantics.byLabel(RegExp('Song A')),
      SemanticsAction.customAction,
      args: moveDown,
    );
    await tester.pumpAndSettle();

    expect(
      await _storedOrder(store),
      <String>['file:///b.mp3', 'file:///a.mp3', 'file:///c.mp3'],
    );

    handle.dispose();
  });

  testWidgets('the handle shows a grab cursor and a hover hint',
      (tester) async {
    await _pump(
      tester,
      store: await _seededStore(),
      controller: FakePlaybackController(),
    );

    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.drag_handle).first));
    await tester.pumpAndSettle();

    // Desktop affordance: the pointer says the handle is draggable before the
    // drag starts, and hovering spells out the keyboard alternative.
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grab,
    );
    expect(find.textContaining('Ctrl'), findsOneWidget);
  });

  testWidgets('mobile keeps the handle drag and the long-press selection',
      (tester) async {
    // The desktop affordances are additive: the handle drag a phone has always
    // had is untouched, and so is the long-press that starts multi-select.
    final InMemoryPlaylistStore store = await _seededStore(
      trackIds: <String>[for (final Track track in _tracks) track.uri],
    );
    await _pump(
      tester,
      store: store,
      controller: FakePlaybackController(),
      platform: TargetPlatform.android,
    );

    await _dragToEnd(tester, from: 0);
    expect(
      await _storedOrder(store),
      <String>['file:///b.mp3', 'file:///c.mp3', 'file:///a.mp3'],
    );

    await tester.longPress(find.text('Song B'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
  });
}
