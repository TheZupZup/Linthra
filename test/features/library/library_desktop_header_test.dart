import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/alphabet_track_list.dart';
import 'package:linthra/features/library/widgets/library_search_field.dart';

import 'fake_music_library_repository.dart';

const List<Track> _tracks = <Track>[
  Track(id: '1', title: 'Arrival', uri: 'file:///1.flac', artistName: 'A'),
  Track(id: '2', title: 'Blue Smoke', uri: 'file:///2.flac', artistName: 'B'),
];

/// A 1600 px window: wide enough that the song column is capped, so where the
/// capped column sits is visible.
Future<void> _pump(WidgetTester tester, {TargetPlatform? platform}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1600, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _tracks),
        ),
      ],
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TabBar _tabs(WidgetTester tester) =>
    tester.widget<TabBar>(find.byKey(const Key('library_tabs')));

void main() {
  group('Library header on a desktop', () {
    testWidgets('tabs sit at their own width under the title', (tester) async {
      await _pump(tester, platform: TargetPlatform.linux);

      expect(_tabs(tester).isScrollable, isTrue);
      expect(_tabs(tester).tabAlignment, TabAlignment.start);
      // The first tab starts where the page title does, not a third of the
      // window along.
      expect(
        tester.getTopLeft(find.text('Songs')).dx,
        closeTo(tester.getTopLeft(find.text('Library')).dx, 1),
      );
    });

    testWidgets('the song column lines up with the search box above it',
        (tester) async {
      await _pump(tester, platform: TargetPlatform.linux);

      expect(
        tester.getTopLeft(find.byType(AlphabetTrackList)).dx,
        tester.getTopLeft(find.byType(LibrarySearchField)).dx,
      );
      // Still capped: past that width a row's title and its menu end up a
      // screen apart.
      expect(
        tester.getSize(find.byType(AlphabetTrackList)).width,
        lessThan(1600),
      );
    });
  });

  group('Library header on a phone layout', () {
    testWidgets('tabs keep sharing the width', (tester) async {
      await _pump(tester);

      expect(_tabs(tester).isScrollable, isFalse);
    });

    testWidgets('a wide window keeps the centred song column', (tester) async {
      await _pump(tester);

      final Rect list = tester.getRect(find.byType(AlphabetTrackList));
      expect(list.center.dx, closeTo(800, 1));
    });
  });
}
