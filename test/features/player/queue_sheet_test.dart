import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';

import 'fake_playback_controller.dart';

Track _track(String id) =>
    Track(id: id, title: 'Song $id', uri: '/$id.mp3', artistName: 'Artist $id');

/// Pumps a host with a button that opens the Queue sheet over the given
/// [controller], faithfully exercising it as the modal bottom sheet it is.
Future<void> _open(
  WidgetTester tester,
  FakePlaybackController controller, {
  InMemoryPlaylistStore? store,
  TargetPlatform? platform,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        if (store != null) playlistStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        builder: (BuildContext context, Widget? child) =>
            Directionality(textDirection: textDirection, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQueueSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Drags the up-next row at [from] by its handle to one end of the list:
/// [toEnd] true drags it past the last row, false past the first.
///
/// Goes through a real pointer sequence rather than calling the reorder
/// callback directly, so the framework's own index bookkeeping is part of what
/// is under test. The travel deliberately overshoots the list — the drop index
/// clamps to the end — which keeps the gesture readable and independent of row
/// metrics, rather than tuned to land on a particular pixel.
Future<void> _dragToEdge(
  WidgetTester tester, {
  required int from,
  required bool toEnd,
}) async {
  final Finder handles = find.byIcon(Icons.drag_handle);
  final int rows = handles.evaluate().length;
  final double rowHeight =
      tester.getCenter(handles.at(1)).dy - tester.getCenter(handles.at(0)).dy;
  final double travel = rowHeight * (rows + 1) * (toEnd ? 1 : -1);
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(handles.at(from)));
  await tester.pumpAndSettle();
  // Two steps rather than one jump, so the list's gap bookkeeping keeps up.
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pumpAndSettle();
  await gesture.moveBy(Offset(0, travel / 2));
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Gives the up-next drag handle at [index] keyboard focus, the way Tab would.
Future<void> _focusHandle(WidgetTester tester, int index) async {
  final Finder handles = find.byIcon(Icons.drag_handle);
  Focus.of(tester.element(handles.at(index))).requestFocus();
  await tester.pumpAndSettle();
}

/// Holds Ctrl + Arrow Down for [repeats] extra auto-repeats, with no frame
/// between them.
///
/// The queue reaches the sheet through a stream, so nothing has rebuilt the
/// rows by the time the repeat arrives: this is the real shape of a held key,
/// and the one case a press-then-pump test cannot reach.
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

/// Presses Ctrl + Arrow Up/Down, the chord that moves the focused row.
Future<void> _pressMoveChord(WidgetTester tester, {required bool down}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(
    down ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowUp,
  );
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// The reorder handle's hover hint, which spells out the keyboard chord.
String _moveHint(WidgetTester tester) {
  return tester
      .widgetList<Tooltip>(find.byType(Tooltip))
      .map((Tooltip t) => t.message ?? '')
      .firstWhere((String m) => m.contains('Reorder'));
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
  group('QueueSheet', () {
    testWidgets('renders the current track and the up-next tracks',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);

      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      // Current track + both up-next tracks are listed.
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
    });

    testWidgets('removing an up-next entry keeps the current track playing',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      // Remove the first up-next track (Song B).
      await tester.tap(find.byTooltip('Remove from queue').first);
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, [_track('C')]);
      expect(find.text('Song B'), findsNothing);
    });

    testWidgets('Clear empties up next but keeps the current track',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(controller.clearCount, 1);
      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, isEmpty);
      expect(find.text('Song B'), findsNothing);
    });

    testWidgets('tapping an up-next track plays it now', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      await tester.tap(find.text('Song C'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('C'));
    });

    testWidgets('shows a drag handle for each upcoming track', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);

      // One handle per up-next track (B and C), not the current one.
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
      expect(find.byType(ReorderableDragStartListener), findsNWidgets(2));
    });

    testWidgets('the drag handle is named, and the row still reads whole',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller);

      // An unnamed handle is the one control on the row nothing announces.
      final SemanticsNode row = tester.getSemantics(find.text('Song B'));
      expect(row.label, contains('Reorder'));
      // The row is still the tap target that plays the track, and the remove
      // action stays its own named button beside it.
      expect(row.flagsCollection.isButton, isTrue);
      expect(find.byTooltip('Remove from queue'), findsOneWidget);

      handle.dispose();
    });

    testWidgets('the playing row says it is the one playing', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller);

      expect(
        tester.getSemantics(find.text('Song A')).label,
        contains('Now playing'),
      );
      expect(
        tester.getSemantics(find.text('Song B')).label,
        isNot(contains('Now playing')),
      );
      handle.dispose();
    });

    testWidgets('dragging an upcoming track to the end lands it last',
        (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);
      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['B', 'C', 'D']);

      // Drag B (the first up-next row) past C and D. A downward move is where
      // the reorder index convention bites: the framework reports the
      // destination *after* the removal, which is what
      // PlaybackQueue.reorderUpNext documents, so the sheet passes it straight
      // through. Re-adding the old adjustment here would leave B second.
      await _dragToEdge(tester, from: 0, toEnd: true);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'D', 'B']);
    });

    testWidgets('dragging an upcoming track to the top lands it first',
        (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);

      // An upward move needs no adjustment in any Flutter version, so it pins
      // the half of the convention the downward case cannot.
      await _dragToEdge(tester, from: 2, toEnd: false);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['D', 'B', 'C']);
    });

    testWidgets('history is shown and tapping it steps back', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);
      await controller.skipToNext(); // current B, history [A], up next [C]

      await _open(tester, controller);

      expect(find.text('Previously played'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);

      await tester.tap(find.text('Song A'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('A'));
    });

    testWidgets('save queue as playlist creates a local playlist',
        (tester) async {
      final store = InMemoryPlaylistStore();
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller, store: store);
      await tester.tap(find.byTooltip('Save queue as playlist'));
      await tester.pumpAndSettle();

      // The shared create-playlist dialog: enter a name, then Create.
      await tester.enterText(find.byType(TextField).first, 'My Queue');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final List<Playlist> saved = await store.load();
      expect(saved, hasLength(1));
      expect(saved.single.name, 'My Queue');
      // Order is history + current + up-next, stored by provider uri.
      expect(saved.single.trackIds, <String>['/A.mp3', '/B.mp3', '/C.mp3']);
      expect(saved.single.source, PlaylistSource.local);
      expect(find.textContaining('Saved 3 songs to'), findsOneWidget);
    });

    testWidgets('never renders a track uri / authenticated source string',
        (tester) async {
      final controller = FakePlaybackController();
      // A remote track whose source reference would carry a token if leaked.
      await controller.playTracks(const <Track>[
        Track(
          id: 'r1',
          title: 'Remote One',
          uri: 'https://host/stream?api_key=SECRETTOKEN123',
          artistName: 'Artist R',
        ),
        Track(
          id: 'r2',
          title: 'Remote Two',
          uri: 'jellyfin:r2',
          artistName: 'Artist R',
        ),
      ]);

      await _open(tester, controller);

      // Titles/artists render; the raw uri and any token never do.
      expect(find.text('Remote One'), findsOneWidget);
      expect(find.text('Remote Two'), findsOneWidget);
      expect(find.textContaining('SECRETTOKEN'), findsNothing);
      expect(find.textContaining('api_key'), findsNothing);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('jellyfin:'), findsNothing);
    });
    testWidgets('Ctrl+Arrow moves the focused row without a pointer',
        (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);
      // Focus B's handle (the first up-next row) and push it down twice.
      await _focusHandle(tester, 0);
      await _pressMoveChord(tester, down: true);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'B', 'D']);
      // Focus followed B to its new row, so the second press moves B again
      // rather than whatever slid into the row it left.
      await _pressMoveChord(tester, down: true);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'D', 'B']);
      // The current track never moves, and nothing restarted: A is still the
      // only track playback was ever handed.
      expect(controller.state.currentTrack, _track('A'));
      expect(controller.playedTracks, <Track>[_track('A')]);
    });

    testWidgets('Ctrl+Arrow up walks a row back to the top', (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);
      await _focusHandle(tester, 2); // D
      await _pressMoveChord(tester, down: false);
      await _pressMoveChord(tester, down: false);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['D', 'B', 'C']);
    });

    testWidgets('a move chord at either end of the queue is a no-op',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      // Up from the first up-next row, and down from the last: both would land
      // outside the list, so both are dropped rather than clamped onto a
      // neighbour or pushed past the playing track.
      await _focusHandle(tester, 0);
      await _pressMoveChord(tester, down: false);
      await _focusHandle(tester, 1);
      await _pressMoveChord(tester, down: true);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['B', 'C']);
      expect(controller.state.currentTrack, _track('A'));
    });

    testWidgets('repeated moves in a row leave the queue coherent',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks(
        <Track>[
          for (final String id in <String>['A', 'B', 'C', 'D', 'E']) _track(id)
        ],
      );

      await _open(tester, controller);
      // Eight moves back to back, changing direction and hitting both ends:
      // every one lands on the queue the previous one left behind, so a stale
      // index would show up as a lost or duplicated track.
      await _focusHandle(tester, 0);
      for (int i = 0; i < 3; i++) {
        await _pressMoveChord(tester, down: true);
      }
      for (int i = 0; i < 5; i++) {
        await _pressMoveChord(tester, down: false);
      }

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['B', 'C', 'D', 'E']);
      expect(controller.state.currentTrack, _track('A'));
      expect(controller.playedTracks, <Track>[_track('A')]);
    });

    testWidgets('shuffled queues reorder the order that is actually playing',
        (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);
      controller.setShuffleEnabled(true);
      final List<String> shuffled =
          controller.state.upNext.map((Track t) => t.id).toList();

      await _open(tester, controller);
      await _focusHandle(tester, 0);
      await _pressMoveChord(tester, down: true);

      // The first two swap; shuffle stays on and the current track is untouched.
      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>[shuffled[1], shuffled[0], shuffled[2]]);
      expect(controller.state.shuffleEnabled, isTrue);
      expect(controller.state.currentTrack, _track('A'));
    });

    testWidgets('rows offer move actions, and only the ones that exist',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);

      // A screen reader gets the same two moves the keyboard chord does.
      expect(
          _customActionsOn(tester, 'Song C'), <String>{'Move up', 'Move down'});
      // The ends of the list only offer the move that goes somewhere.
      expect(_customActionsOn(tester, 'Song B'), <String>{'Move down'});
      expect(_customActionsOn(tester, 'Song D'), <String>{'Move up'});

      handle.dispose();
    });

    testWidgets('the drag handle answers a screen reader move', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B'), _track('C')]);

      await _open(tester, controller);
      final int moveDown = tester
          .getSemantics(find.text('Song B'))
          .getSemanticsData()
          .customSemanticsActionIds!
          .firstWhere(
            (int id) =>
                CustomSemanticsAction.getAction(id)!.label == 'Move down',
          );
      tester.semantics.performAction(
        find.semantics.byLabel(RegExp('Song B')),
        SemanticsAction.customAction,
        args: moveDown,
      );
      await tester.pumpAndSettle();

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'B']);

      handle.dispose();
    });

    testWidgets('the handle shows a grab cursor and a hover hint',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller);

      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.drag_handle)));
      await tester.pumpAndSettle();

      // Desktop affordance: the pointer says the handle is draggable before the
      // drag starts, and hovering spells out the keyboard alternative.
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.grab,
      );
      expect(find.textContaining('Ctrl'), findsOneWidget);
    });
    testWidgets('a held chord keeps walking the same track', (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);
      await _focusHandle(tester, 0);
      // Two presses, no frame in between. Reading the source index off the
      // handle that fired would apply the second move to the queue the first
      // one already changed, and land B back where it started.
      await _holdMoveChordDown(tester);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'D', 'B']);
    });

    testWidgets('a walk past the bottom of the sheet still moves one track',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks(<Track>[
        for (int i = 0; i < 30; i++) _track(i.toString().padLeft(2, '0')),
      ]);

      await _open(tester, controller);
      await _focusHandle(tester, 0);
      // Twelve rows is further than the sheet shows at once. Focus can only
      // land on a row the sliver built, so without scrolling the walk strands
      // itself partway down and starts moving whichever track slid into the
      // row it left.
      for (int i = 0; i < 12; i++) {
        await _pressMoveChord(tester, down: true);
      }

      final List<String> upNext =
          controller.state.upNext.map((Track t) => t.id).toList();
      expect(upNext.indexOf('01'), 12);
      // Nothing else moved, and nothing was lost on the way down.
      expect(upNext.length, 29);
      expect(upNext..remove('01'), <String>[
        for (int i = 2; i < 30; i++) i.toString().padLeft(2, '0'),
      ]);
    });
    testWidgets('a chord after a pointer drag moves the track that was dragged',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks(
        [_track('A'), _track('B'), _track('C'), _track('D'), _track('E')],
      );

      await _open(tester, controller);
      // Focus B's handle, then drag B to the end with the mouse. Focus nodes
      // are per position, so without a handoff the focus would be left on the
      // row C slid into and the chord below would move C (or, at the top of
      // the list, do nothing at all).
      await _focusHandle(tester, 0);
      await _dragToEdge(tester, from: 0, toEnd: true);
      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'D', 'E', 'B']);

      await _pressMoveChord(tester, down: false);

      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'D', 'B', 'E']);
    });

    testWidgets('a drag past a focused row carries that row along',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks(
        [_track('A'), _track('B'), _track('C'), _track('D'), _track('E')],
      );

      await _open(tester, controller);
      // Focus D, then drag B from the top past it. D is now one row higher, so
      // the chord has to follow D rather than stay on the index it used to sit
      // at — which E has since slid into.
      await _focusHandle(tester, 2); // up next is [B, C, D, E]
      await _dragToEdge(tester, from: 0, toEnd: true);
      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['C', 'D', 'E', 'B']);

      await _pressMoveChord(tester, down: false);

      // D moved up. Staying on the stale index would have moved E instead,
      // giving [C, E, D, B].
      expect(controller.state.upNext.map((Track t) => t.id).toList(),
          <String>['D', 'C', 'E', 'B']);
    });

    testWidgets('a mouse drag alone never pulls focus into the queue',
        (tester) async {
      final controller = FakePlaybackController();
      await controller
          .playTracks([_track('A'), _track('B'), _track('C'), _track('D')]);

      await _open(tester, controller);
      await _dragToEdge(tester, from: 0, toEnd: true);

      // Nothing was focused before the drag, so nothing is after it: the
      // handoff only moves focus that already existed.
      expect(
        find
            .byIcon(Icons.drag_handle)
            .evaluate()
            .any((Element e) => Focus.of(e).hasFocus),
        isFalse,
      );
    });

    testWidgets('the hover hint names the modifier that works on this platform',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller, platform: TargetPlatform.macOS);

      // Ctrl + arrow is Mission Control on macOS and never reaches the app, so
      // a hint naming it would send people to a chord the OS eats.
      expect(_moveHint(tester), contains('Cmd'));
      expect(_moveHint(tester), isNot(contains('Ctrl')));
    });

    testWidgets('the hover hint says Ctrl on Linux', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller, platform: TargetPlatform.linux);

      expect(_moveHint(tester), contains('Ctrl'));
    });
  });

  group('where the queue opens', () {
    final Finder sideSheet = find.byKey(const Key('queue_side_sheet'));

    testWidgets('a phone keeps the bottom sheet', (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(sideSheet, findsNothing);
    });

    testWidgets('a desktop opens it from the side, as the pane',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller, platform: TargetPlatform.linux);

      expect(find.byType(BottomSheet), findsNothing);
      expect(sideSheet, findsOneWidget);
      expect(tester.getRect(sideSheet).right, 800);
      expect(
        tester.widget<QueueSheet>(find.byType(QueueSheet)).embedded,
        isTrue,
      );
      expect(find.text('Song B'), findsOneWidget);
    });

    testWidgets('the close button, Escape and a click beside it close it',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(tester, controller, platform: TargetPlatform.linux);
      await tester.tap(find.byTooltip('Close queue'));
      await tester.pumpAndSettle();
      expect(sideSheet, findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(sideSheet, findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();
      expect(sideSheet, findsNothing);
    });

    testWidgets('a right-to-left desktop opens it from the left',
        (tester) async {
      final controller = FakePlaybackController();
      await controller.playTracks([_track('A'), _track('B')]);

      await _open(
        tester,
        controller,
        platform: TargetPlatform.linux,
        textDirection: TextDirection.rtl,
      );

      expect(tester.getRect(sideSheet).left, 0);
    });
  });
}
