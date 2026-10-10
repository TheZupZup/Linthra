import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/widgets/alphabet_track_list.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/shared/focus/focus_ring.dart';

List<Track> _alphabetTracks() {
  return [
    for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++)
      Track(
        id: '$code',
        title: '${String.fromCharCode(code)} Track',
        uri: 'file:///$code.mp3',
      ),
  ];
}

Future<void> _pump(
  WidgetTester tester,
  List<Track> tracks, {
  double width = 400,
  double height = 500,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: AlphabetTrackList(tracks: tracks),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('AlphabetTrackList', () {
    testWidgets('renders rows and the A–Z index rail', (tester) async {
      await _pump(tester, _alphabetTracks());

      expect(find.byType(TrackTile), findsWidgets);
      expect(find.byKey(const Key('library_alphabet_index')), findsOneWidget);
      // The first section is visible; a far-down one is not yet built.
      expect(find.text('A Track'), findsOneWidget);
      expect(find.text('Z Track'), findsNothing);
    });

    testWidgets('pins the index to the trailing edge as a narrow rail', (
      tester,
    ) async {
      await _pump(tester, _alphabetTracks());

      final railRect =
          tester.getRect(find.byKey(const Key('library_alphabet_index')));
      final listRect =
          tester.getRect(find.byKey(const Key('library_track_list')));

      // Anchored to the right edge of the list, not floating in the centre.
      expect(railRect.right, closeTo(listRect.right, 1));
      expect(railRect.left, greaterThan(listRect.center.dx));
      // And it's a slim touch target, not a wide overlay over the rows.
      expect(railRect.width, lessThanOrEqualTo(32));
    });

    testWidgets('rows keep their text and overflow menu beside the rail', (
      tester,
    ) async {
      await _pump(tester, _alphabetTracks());

      expect(find.text('A Track'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsWidgets);

      // The overflow menu sits to the left of the rail, never under it.
      final railRect =
          tester.getRect(find.byKey(const Key('library_alphabet_index')));
      final menuRect = tester.getRect(find.byIcon(Icons.more_vert).first);
      expect(menuRect.right, lessThanOrEqualTo(railRect.left + 1));
    });

    testWidgets('tapping the index jumps the list to that section', (
      tester,
    ) async {
      await _pump(tester, _alphabetTracks());

      // Tap near the bottom of the rail to jump to the last letter ('Z').
      final rail = find.byKey(const Key('library_alphabet_index'));
      final rect = tester.getRect(rail);
      await tester.tapAt(Offset(rect.center.dx, rect.bottom - 2));
      await tester.pumpAndSettle();

      expect(find.text('Z Track'), findsOneWidget);
      expect(find.text('A Track'), findsNothing);
    });

    testWidgets('lays out without overflow on a narrow phone width', (
      tester,
    ) async {
      await _pump(tester, _alphabetTracks(), width: 280);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('library_alphabet_index')), findsOneWidget);
      expect(find.byType(TrackTile), findsWidgets);
    });

    testWidgets('hides the rail when there are too few sections', (
      tester,
    ) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Alpha', uri: 'file:///a.mp3'),
        Track(id: '2', title: 'Another', uri: 'file:///b.mp3'),
      ]);

      // Only one section ('A') → no rail to render.
      expect(find.byKey(const Key('library_alphabet_index')), findsNothing);
    });
  });

  // The rail as the keyboard and a screen reader meet it (#860): each letter is
  // a button of its own, while the pointer still scrubs the rail as a whole.
  group('AlphabetTrackList index letters', () {
    Finder letter(String value) => find.descendant(
          of: find.byKey(const Key('library_alphabet_index')),
          matching: find.text(value),
        );

    FocusNode letterNode(WidgetTester tester, String value) =>
        Focus.of(tester.element(letter(value)));

    String? focusedRowTitle() {
      final TrackTile? tile = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TrackTile>();
      return tile?.tracks[tile.index].title;
    }

    testWidgets('each letter is a button, and the active one is selected', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, _alphabetTracks());

      expect(
        tester.getSemantics(find.bySemanticsLabel('Jump to A')),
        matchesSemantics(
          label: 'Jump to A',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Jump to M')),
        matchesSemantics(
          label: 'Jump to M',
          isButton: true,
          hasSelectedState: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a screen reader tap on a letter jumps to its section', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, _alphabetTracks());

      tester.semantics.tap(find.semantics.byLabel('Jump to Z'));
      await tester.pumpAndSettle();

      expect(find.text('Z Track'), findsOneWidget);
      expect(find.text('A Track'), findsNothing);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Jump to Z')),
        matchesSemantics(
          label: 'Jump to Z',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a number or symbol section says what it holds', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, <Track>[
        const Track(id: '1', title: '1999', uri: 'file:///1.mp3'),
        ..._alphabetTracks(),
      ]);

      expect(
        find.bySemanticsLabel('Jump to songs starting with a number or symbol'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('Tab moves from one letter to the next', (tester) async {
      await _pump(tester, _alphabetTracks());

      letterNode(tester, 'M').requestFocus();
      await tester.pump();
      expect(letterNode(tester, 'M').hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(letterNode(tester, 'N').hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(letterNode(tester, 'O').hasPrimaryFocus, isTrue);
    });

    testWidgets('the focused letter is ringed', (tester) async {
      await _pump(tester, _alphabetTracks());
      // Any key puts Flutter in keyboard highlight mode, as a real Tab would.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);

      letterNode(tester, 'M').requestFocus();
      await tester.pump();

      expect(
        find.ancestor(of: letter('M'), matching: find.byType(FocusRing)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('library_alphabet_index')),
          matching: find.byKey(focusRingKey),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Enter on a letter jumps to its section and keeps focus', (
      tester,
    ) async {
      await _pump(tester, _alphabetTracks());

      letterNode(tester, 'Z').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Z Track'), findsOneWidget);
      expect(find.text('A Track'), findsNothing);
      expect(letterNode(tester, 'Z').hasPrimaryFocus, isTrue);
    });

    testWidgets('Space on a letter jumps too', (tester) async {
      await _pump(tester, _alphabetTracks());

      letterNode(tester, 'P').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.text('P Track'), findsOneWidget);
      expect(find.text('A Track'), findsNothing);
    });

    testWidgets('dragging down the rail still scrubs to the last section', (
      tester,
    ) async {
      await _pump(tester, _alphabetTracks());

      final Rect rail =
          tester.getRect(find.byKey(const Key('library_alphabet_index')));
      final TestGesture gesture =
          await tester.startGesture(Offset(rail.center.dx, rail.top + 2));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      // The bubble shows while the finger is down, and goes with it.
      final Finder bubble = find.byWidgetPredicate(
        (Widget w) => w.runtimeType.toString() == '_ScrubBubble',
      );
      expect(bubble, findsOneWidget);

      await gesture.moveTo(Offset(rail.center.dx, rail.bottom - 2));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(bubble, findsNothing);
      expect(find.text('Z Track'), findsOneWidget);
      expect(find.text('A Track'), findsNothing);
    });

    testWidgets('End from a row still lands on the last row, not the rail', (
      tester,
    ) async {
      await _pump(tester, _alphabetTracks());

      Focus.of(tester.element(find.text('A Track'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();

      expect(focusedRowTitle(), 'Z Track');
    });
  });
}
