import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';
import 'package:linthra/features/player/widgets/queue_side_panel.dart';

import 'fake_playback_controller.dart';

/// The desktop queue column (#416), on its own.
///
/// The panel is a *host* for the queue, not a second copy of it: everything
/// here is asserted against the controller the rest of the app reads, so a test
/// that passes with a private list in the widget would fail on the state that
/// actually plays. Where it is drawn at all is the shell's business and is
/// pinned in `test/features/shell/queue_side_panel_shell_test.dart`.

Track _track(String id) => Track(
    id: id, title: 'Song $id', uri: 'jellyfin:$id', artistName: 'Artist $id');

/// Pumps the panel at its real width beside a stand-in page, so the rows are
/// laid out in the box the shell actually gives them.
Future<void> _pumpPanel(
  WidgetTester tester,
  FakePlaybackController controller, {
  VoidCallback? onClose,
  Size size = const Size(1600, 900),
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Row(
                children: <Widget>[
                  const Expanded(child: Center(child: Text('page'))),
                  QueueSidePanel(onClose: onClose ?? () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Gives the up-next drag handle at [index] keyboard focus, the way Tab would.
Future<void> _focusHandle(WidgetTester tester, int index) async {
  final Finder handles = find.byIcon(Icons.drag_handle);
  Focus.of(tester.element(handles.at(index))).requestFocus();
  await tester.pumpAndSettle();
}

/// Presses Ctrl + Arrow Down, the chord that moves the focused row.
Future<void> _pressMoveChordDown(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// The titles the panel is listing under "Up next", top to bottom.
List<String> _upNextTitles(WidgetTester tester) {
  final Finder handles = find.byIcon(Icons.drag_handle);
  return <String>[
    for (int i = 0; i < handles.evaluate().length; i++)
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.ancestor(
                    of: handles.at(i),
                    matching: find.byType(ListTile),
                  ),
                  matching: find.byType(Text),
                )
                .first,
          )
          .data!,
  ];
}

void main() {
  group('QueueSidePanel', () {
    testWidgets('shows what is playing and what is next', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller
          .playTracks(<Track>[_track('A'), _track('B'), _track('C')]);

      await _pumpPanel(tester, controller);

      expect(find.text('Queue'), findsOneWidget);
      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);
      expect(find.text('Song C'), findsOneWidget);
      // The page beside it is still there: a column, not a cover.
      expect(find.text('page'), findsOneWidget);
    });

    testWidgets('the playing row is the one marked as playing', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[_track('A'), _track('B')]);

      await _pumpPanel(tester, controller);

      expect(
        tester.getSemantics(find.text('Song A')).label,
        contains('Now playing'),
      );
      expect(
        tester.getSemantics(find.text('Song B')).label,
        isNot(contains('Now playing')),
      );
      semantics.dispose();
    });

    testWidgets('the highlight follows the track that is actually playing',
        (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[_track('A'), _track('B')]);

      await _pumpPanel(tester, controller);
      // Skipped from somewhere else entirely: a media key, the mini-player,
      // the queue running on. The panel hears it through the same state stream.
      await controller.skipToNext();
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('Song B')).label,
        contains('Now playing'),
      );
      // B was the last one queued, so there is nothing after it now.
      expect(find.textContaining('Nothing up next'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a source fallback leaves the queue exactly where it was',
        (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller
          .playTracks(<Track>[_track('A'), _track('B'), _track('C')]);

      await _pumpPanel(tester, controller);

      // The same logical track, now coming from a different copy: the server
      // went away and the downloaded file took over. Nothing about the queue
      // changed, so nothing about the panel may.
      controller.emit(
        controller.state.copyWith(source: PlaybackSource.offlineCache),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('Song A')).label,
        contains('Now playing'),
      );
      expect(_upNextTitles(tester), <String>['Song B', 'Song C']);
      // And nothing about where the audio comes from leaks into the rows.
      expect(find.textContaining('OFFLINE CACHE'), findsNothing);
      semantics.dispose();
    });

    testWidgets('nothing playing is said plainly', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);

      await _pumpPanel(tester, controller);

      expect(find.text('Nothing playing'), findsOneWidget);
      expect(find.text('Up next'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a one-track queue says there is nothing after it',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[_track('A')]);

      await _pumpPanel(tester, controller);

      expect(find.text('Song A'), findsOneWidget);
      expect(find.textContaining('Nothing up next'), findsOneWidget);
      expect(find.byIcon(Icons.drag_handle), findsNothing);
    });

    testWidgets('a track added while the panel is open shows up at once',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[_track('A')]);

      await _pumpPanel(tester, controller);
      expect(find.text('Song Z'), findsNothing);

      // Queued from the library, two panes away.
      controller.addToQueue(_track('Z'));
      await tester.pumpAndSettle();

      expect(find.text('Song Z'), findsOneWidget);
      expect(controller.state.upNext, <Track>[_track('Z')]);
    });

    testWidgets('removing a row removes it from the real queue',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller
          .playTracks(<Track>[_track('A'), _track('B'), _track('C')]);

      await _pumpPanel(tester, controller);
      await tester.tap(find.byTooltip('Remove from queue').first);
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, <Track>[_track('C')]);
      expect(find.text('Song B'), findsNothing);
    });

    testWidgets('tapping an upcoming row plays it now', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller
          .playTracks(<Track>[_track('A'), _track('B'), _track('C')]);

      await _pumpPanel(tester, controller);
      await tester.tap(find.text('Song C'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack, _track('C'));
    });

    testWidgets('the keyboard reorders the real queue, not a local copy',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller
          .playTracks(<Track>[_track('A'), _track('B'), _track('C')]);

      await _pumpPanel(tester, controller);
      await _focusHandle(tester, 0);
      await _pressMoveChordDown(tester);

      expect(controller.state.upNext, <Track>[_track('C'), _track('B')]);
      expect(_upNextTitles(tester), <String>['Song C', 'Song B']);
    });

    testWidgets('shuffling reshuffles the list the panel is showing',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[
        for (final String id in <String>['A', 'B', 'C', 'D', 'E']) _track(id),
      ]);

      await _pumpPanel(tester, controller);
      controller.setShuffleEnabled(true);
      await tester.pumpAndSettle();

      // Whatever the shuffle produced, the panel is showing that order (the
      // one that is going to play) rather than the order it was built with.
      expect(
        _upNextTitles(tester),
        <String>[
          for (final Track track in controller.state.upNext) track.title
        ],
      );
    });

    testWidgets('a very long title is trimmed, not overflowed', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final Track long = Track(
        id: 'long',
        title: 'A Title That Goes On ${'and on ' * 40}Forever',
        uri: 'jellyfin:long',
        artistName: 'Artist ${'Long ' * 40}',
      );
      await controller.playTracks(<Track>[_track('A'), long]);

      await _pumpPanel(tester, controller);

      expect(tester.takeException(), isNull);
      final Text title = tester.widget<Text>(find.text(long.title));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('the header still fits at a large text scale', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[_track('A'), _track('B')]);

      await _pumpPanel(tester, controller, textScale: 1.6);

      // A fixed-width column with four header controls is exactly where an
      // overflow shows up first.
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Close queue'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('a very long queue only builds the rows on screen',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[
        for (int i = 0; i < 1000; i++) _track('$i'),
      ]);

      await _pumpPanel(tester, controller);

      // A thousand queued songs must cost a screenful of rows, not a thousand:
      // the up-next list is a sliver, and this is what keeps it one.
      final int built = find.byIcon(Icons.drag_handle).evaluate().length;
      expect(built, lessThan(60));
      expect(built, greaterThan(0));
      expect(controller.state.upNext, hasLength(999));
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing asks the host to collapse, and touches nothing else',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[_track('A'), _track('B')]);

      int closes = 0;
      await _pumpPanel(tester, controller, onClose: () => closes++);
      await tester.tap(find.byTooltip('Close queue'));
      await tester.pumpAndSettle();

      expect(closes, 1);
      // Collapsing a column is not a playback command.
      expect(controller.state.currentTrack, _track('A'));
      expect(controller.state.upNext, <Track>[_track('B')]);
      expect(controller.pauseCount, 0);
      expect(controller.stopCount, 0);
    });

    testWidgets('never renders a uri or an authenticated source string',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(const <Track>[
        Track(
          id: 'r1',
          title: 'Remote One',
          uri: 'https://host/stream?api_key=SECRETTOKEN123',
          artistName: 'Artist R',
        ),
        Track(id: 'r2', title: 'Remote Two', uri: 'jellyfin:r2'),
      ]);

      await _pumpPanel(tester, controller);

      expect(find.text('Remote One'), findsOneWidget);
      expect(find.text('Remote Two'), findsOneWidget);
      expect(find.textContaining('SECRETTOKEN'), findsNothing);
      expect(find.textContaining('api_key'), findsNothing);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('jellyfin:'), findsNothing);
    });

    testWidgets('the column is one named region for a screen reader',
        (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[_track('A'), _track('B')]);

      await _pumpPanel(tester, controller);

      // The nearest semantics node above the queue itself is the panel's own
      // region node, rather than the page's.
      expect(
        tester.getSemantics(find.byType(QueueSheet)).label,
        contains('Queue'),
      );
      // Named, but not merged: the rows keep their own labels and actions.
      expect(
        tester.getSemantics(find.text('Song B')).label,
        contains('Song B'),
      );
      semantics.dispose();
    });
  });
}
