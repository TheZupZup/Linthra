import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/playlists/playlist_drag.dart';
import 'package:linthra/features/shell/home_shell.dart';
import 'package:linthra/features/shell/playlist_drag_spring.dart';

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');

/// A stand-in for the shell: a draggable row on the right, and the spring
/// wrapping a rail-shaped strip on the left.
class _Harness extends StatelessWidget {
  const _Harness({required this.sprung});

  final List<int> sprung;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux),
      home: Scaffold(
        body: Row(
          children: <Widget>[
            SizedBox(
              width: 128,
              height: 600,
              child: PlaylistDragSpring(
                onSpring: () => sprung.add(sprung.length),
                builder: (BuildContext context, bool hovering) {
                  return ColoredBox(
                    color: const Color(0xFFEEEEEE),
                    child: Center(
                      child: Text(hovering ? 'rail: hovering' : 'rail: idle'),
                    ),
                  );
                },
              ),
            ),
            Expanded(
              child: SizedBox(
                height: 600,
                child: PlaylistTrackDraggable(
                  tracks: () => <Track>[_local('a')],
                  child: const Center(child: Text('source row')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks up the source row and holds the pointer over the rail.
Future<TestGesture> _dragOntoRail(WidgetTester tester) async {
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(find.text('source row')));
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.byType(PlaylistDragSpring)));
  await tester.pump();
  return gesture;
}

void main() {
  group('the rail springs to Playlists mid-drag', () {
    testWidgets('a drag resting on the rail switches tab', (tester) async {
      final sprung = <int>[];
      await tester.pumpWidget(_Harness(sprung: sprung));

      final TestGesture gesture = await _dragOntoRail(tester);
      expect(sprung, isEmpty, reason: 'not before the dwell elapses');

      await tester.pump(PlaylistDragSpring.dwell);
      expect(sprung, hasLength(1));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('crossing the rail on the way past does not', (tester) async {
      // The whole point of the dwell: a drag that sweeps over the rail towards
      // something else must not yank the page out from under it.
      final sprung = <int>[];
      await tester.pumpWidget(_Harness(sprung: sprung));

      final TestGesture gesture = await _dragOntoRail(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(tester.getCenter(find.text('source row')));
      await tester.pump(PlaylistDragSpring.dwell * 2);

      expect(sprung, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('the rail says where the drag is headed', (tester) async {
      // Growable: the spring appends to this when it fires, so a const literal
      // here would throw rather than record.
      final sprung = <int>[];
      await tester.pumpWidget(_Harness(sprung: sprung));
      expect(find.text('rail: idle'), findsOneWidget);

      final TestGesture gesture = await _dragOntoRail(tester);
      expect(find.text('rail: hovering'), findsOneWidget);

      await gesture.moveTo(tester.getCenter(find.text('source row')));
      await tester.pump();
      expect(find.text('rail: idle'), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('it springs once per hover, not once per pointer move',
        (tester) async {
      final sprung = <int>[];
      await tester.pumpWidget(_Harness(sprung: sprung));

      final TestGesture gesture = await _dragOntoRail(tester);
      await tester.pump(PlaylistDragSpring.dwell);
      // Keep wandering around inside the rail well past a second dwell.
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(PlaylistDragSpring.dwell);
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump(PlaylistDragSpring.dwell);

      expect(sprung, hasLength(1));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('the rail never swallows the drop', (tester) async {
      // The spring is a route to the playlists, not a destination. If it took
      // the drop, the drag would end on the rail and never reach a playlist.
      final sprung = <int>[];
      await tester.pumpWidget(_Harness(sprung: sprung));

      final TestGesture gesture = await _dragOntoRail(tester);
      await tester.pump(PlaylistDragSpring.dwell);
      await gesture.up();
      await tester.pumpAndSettle();

      final DragTarget<PlaylistDragPayload> target = tester.widget(
        find.byType(DragTarget<PlaylistDragPayload>),
      );
      expect(
        target.onWillAcceptWithDetails!(
          DragTargetDetails<PlaylistDragPayload>(
            data: PlaylistDragPayload(() => <Track>[_local('a')]),
            offset: Offset.zero,
          ),
        ),
        isFalse,
      );
    });

    testWidgets('a drag that ends inside the dwell springs nothing',
        (tester) async {
      final sprung = <int>[];
      await tester.pumpWidget(_Harness(sprung: sprung));

      final TestGesture gesture = await _dragOntoRail(tester);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(PlaylistDragSpring.dwell * 2);

      expect(sprung, isEmpty);
    });
  });

  group('the shell agrees with the spring about which branch is which', () {
    test('playlistsBranchIndex points at the Playlists destination', () {
      // A const constructor cannot assert this, and getting it wrong would
      // spring a drag to Downloads.
      expect(
        HomeShell.destinationLabels[HomeShell.playlistsBranchIndex],
        'Playlists',
      );
    });
  });
}
