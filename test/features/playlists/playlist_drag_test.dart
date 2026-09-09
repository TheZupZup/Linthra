import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/playlists/playlist_drag.dart';

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

/// A source row on the left and a playlist row on the right, far enough apart
/// that a drag between them is unambiguously horizontal.
class _Harness extends StatelessWidget {
  const _Harness({
    required this.playlist,
    required this.tracks,
    required this.dropped,
    required this.refusals,
    this.platform = TargetPlatform.linux,
    this.onResolve,
  });

  final Playlist playlist;
  final List<Track> tracks;
  final List<List<Track>> dropped;
  final List<String> refusals;
  final TargetPlatform platform;

  /// Counts how many times the payload closure ran, so a test can pin that it
  /// is not walked on every rebuild.
  final VoidCallback? onResolve;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: Row(
          children: <Widget>[
            SizedBox(
              width: 200,
              height: 80,
              child: PlaylistTrackDraggable(
                tracks: () {
                  onResolve?.call();
                  return tracks;
                },
                child: const ColoredBox(
                  color: Color(0xFF2196F3),
                  child: Center(child: Text('source row')),
                ),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 200,
              height: 80,
              child: PlaylistDropRegion(
                playlist: playlist,
                onDrop: dropped.add,
                onRefused: refusals.add,
                builder: (BuildContext context, PlaylistDropState state) {
                  return PlaylistDropHighlight(
                    state: state,
                    child: Center(child: Text('drop: ${state.name}')),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Drags the source row onto the drop region and releases, in the small steps
/// a real pointer moves in so the target enters and leaves properly.
Future<void> _dragSourceToTarget(WidgetTester tester) async {
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(find.text('source row')));
  // Horizontal first: the draggable is horizontally-affine, so this is what
  // wins the gesture arena and starts the drag.
  await gesture.moveBy(const Offset(40, 0));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.byType(PlaylistDropRegion)));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('what a drag picks up', () {
    test('an unselected row drags itself', () {
      expect(
        dragPayloadFor(
          track: _local('a'),
          selectionActive: false,
          selected: false,
          selection: () => <Track>[_local('x'), _local('y')],
        ).map((Track t) => t.uri),
        <String>['file:///a.mp3'],
      );
    });

    test('a selected row drags the whole selection', () {
      expect(
        dragPayloadFor(
          track: _local('a'),
          selectionActive: true,
          selected: true,
          selection: () => <Track>[_local('a'), _local('b')],
        ).map((Track t) => t.uri),
        <String>['file:///a.mp3', 'file:///b.mp3'],
      );
    });

    test('an unselected row inside a live selection still drags itself', () {
      // What every desktop list does: the drag is about the row under the
      // pointer, not about what happens to be ticked elsewhere.
      expect(
        dragPayloadFor(
          track: _local('c'),
          selectionActive: true,
          selected: false,
          selection: () => <Track>[_local('a'), _local('b')],
        ).map((Track t) => t.uri),
        <String>['file:///c.mp3'],
      );
    });

    test('a selection that no longer holds this row falls back to it', () {
      // The row was filtered out or removed from under the selection.
      // Dragging nothing would be worse than dragging what the pointer is on.
      expect(
        dragPayloadFor(
          track: _local('a'),
          selectionActive: true,
          selected: true,
          selection: () => <Track>[],
        ).map((Track t) => t.uri),
        <String>['file:///a.mp3'],
      );
    });

    test('a host with no selection at all drags the row', () {
      expect(
        dragPayloadFor(
          track: _local('a'),
          selectionActive: true,
          selected: true,
          selection: null,
        ).map((Track t) => t.uri),
        <String>['file:///a.mp3'],
      );
    });
  });

  group('drag a track onto a playlist', () {
    testWidgets('a drop hands the target every dragged track', (tester) async {
      final dropped = <List<Track>>[];
      await tester.pumpWidget(_Harness(
        playlist: const Playlist(id: 'p1', name: 'My Mix'),
        tracks: <Track>[_local('a'), _local('b')],
        dropped: dropped,
        refusals: <String>[],
      ));

      await _dragSourceToTarget(tester);

      expect(dropped.single.map((Track t) => t.uri).toList(),
          <String>['file:///a.mp3', 'file:///b.mp3']);
    });

    testWidgets('a playlist that can take nothing refuses, and says why',
        (tester) async {
      final dropped = <List<Track>>[];
      final refusals = <String>[];
      await tester.pumpWidget(_Harness(
        playlist: const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
        ),
        tracks: <Track>[_local('a')],
        dropped: dropped,
        refusals: refusals,
      ));

      await _dragSourceToTarget(tester);

      // Nothing written, and the user is told rather than left watching the
      // drag bounce back with no explanation.
      expect(dropped, isEmpty);
      expect(
          refusals.single, 'Only Jellyfin tracks can be added to Server Mix.');
    });

    testWidgets('a mixed selection lands its supported half', (tester) async {
      final dropped = <List<Track>>[];
      final refusals = <String>[];
      await tester.pumpWidget(_Harness(
        playlist: const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
        ),
        tracks: <Track>[_local('a'), _jellyfin('1')],
        dropped: dropped,
        refusals: refusals,
      ));

      await _dragSourceToTarget(tester);

      // The whole selection is handed over; deciding which half is addable is
      // the plan's job, not the drop region's.
      expect(dropped.single, hasLength(2));
      expect(refusals, isEmpty);
    });
  });

  group('the target says what a drop would do before it happens', () {
    testWidgets('an acceptable payload highlights it', (tester) async {
      await tester.pumpWidget(_Harness(
        playlist: const Playlist(id: 'p1', name: 'My Mix'),
        tracks: <Track>[_local('a')],
        dropped: <List<Track>>[],
        refusals: <String>[],
      ));
      expect(find.text('drop: idle'), findsOneWidget);

      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(find.text('source row')));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(PlaylistDropRegion)));
      await tester.pump();

      expect(find.text('drop: accepted'), findsOneWidget);

      // ...and it goes back to idle once the drag leaves again.
      await gesture.moveTo(tester.getCenter(find.text('source row')));
      await tester.pump();
      expect(find.text('drop: idle'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a payload it cannot take shows as refused, not as idle',
        (tester) async {
      await tester.pumpWidget(_Harness(
        playlist: const Playlist(
          id: 'p1',
          name: 'Server Mix',
          source: PlaylistSource.jellyfin,
        ),
        tracks: <Track>[_local('a')],
        dropped: <List<Track>>[],
        refusals: <String>[],
      ));

      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(find.text('source row')));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(PlaylistDropRegion)));
      await tester.pump();

      // A target that stayed inert would leave the user guessing why the drop
      // did nothing.
      expect(find.text('drop: refused'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('the drag is desktop-only, and does not fight the list', () {
    testWidgets('mobile has no draggable at all', (tester) async {
      final dropped = <List<Track>>[];
      await tester.pumpWidget(_Harness(
        platform: TargetPlatform.android,
        playlist: const Playlist(id: 'p1', name: 'My Mix'),
        tracks: <Track>[_local('a')],
        dropped: dropped,
        refusals: <String>[],
      ));

      expect(find.byType(Draggable<PlaylistDragPayload>), findsNothing);
      await _dragSourceToTarget(tester);
      expect(dropped, isEmpty);
    });

    testWidgets('a vertical pull is left to the scroller', (tester) async {
      // The rows live in a scrollable here, which is the situation that
      // matters: if the drag won a vertical pull, a long track list would stop
      // scrolling with a mouse.
      final dropped = <List<Track>>[];
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: <Widget>[
              for (int i = 0; i < 30; i++)
                SizedBox(
                  height: 80,
                  child: PlaylistTrackDraggable(
                    tracks: () => <Track>[_local('$i')],
                    child: Center(child: Text('row $i')),
                  ),
                ),
            ],
          ),
        ),
      ));

      await tester.drag(find.text('row 0'), const Offset(0, -200));
      await tester.pumpAndSettle();

      // The list scrolled the whole pull, less the slop `drag` spends getting
      // the gesture recognised. Nothing was picked up.
      expect(controller.offset, 200 - kDragSlopDefault);
      expect(dropped, isEmpty);
    });
  });

  group('the payload is resolved lazily', () {
    testWidgets('no drag means the selection is never walked', (tester) async {
      int resolved = 0;
      await tester.pumpWidget(_Harness(
        playlist: const Playlist(id: 'p1', name: 'My Mix'),
        tracks: <Track>[_local('a')],
        dropped: <List<Track>>[],
        refusals: <String>[],
        onResolve: () => resolved++,
      ));
      await tester.pump();

      // A row cannot afford to resolve "the current selection" on every build:
      // with a 200k-track library that is an O(n) walk per row per frame.
      expect(resolved, 0);
    });

    testWidgets('a whole drag resolves it once', (tester) async {
      int resolved = 0;
      await tester.pumpWidget(_Harness(
        playlist: const Playlist(id: 'p1', name: 'My Mix'),
        tracks: <Track>[_local('a')],
        dropped: <List<Track>>[],
        refusals: <String>[],
        onResolve: () => resolved++,
      ));

      await _dragSourceToTarget(tester);

      // The feedback card asks once when the drag starts; every hover and the
      // drop itself read the payload's cached answer.
      expect(resolved, 1);
    });
  });
}
