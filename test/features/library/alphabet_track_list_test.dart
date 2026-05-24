import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/widgets/alphabet_track_list.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';

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

Future<void> _pump(WidgetTester tester, List<Track> tracks) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: AlphabetTrackList(tracks: tracks),
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
}
