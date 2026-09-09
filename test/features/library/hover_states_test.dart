import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/features/library/widgets/album_grid.dart';
import 'package:linthra/features/library/widgets/album_grid_card.dart';
import 'package:linthra/shared/widgets/hover_highlight.dart';

/// Hover feedback (#385). A mouse user has to be able to tell what is
/// interactive, and hover has to stay distinct from selected, focused and
/// pressed — a row that looks selected because a pointer is resting on it is
/// worse than no feedback at all.
final List<Album> _albums = <Album>[
  for (int i = 0; i < 6; i++)
    Album(id: '$i', title: 'Album $i', artistName: 'Artist $i', trackCount: 9),
];

Future<void> _pumpGrid(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark(BrandPalettes.classic),
        home: Scaffold(
          body: AlbumGrid(albums: _albums, onOpen: (_) {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A real mouse, so hover happens at all: a touch pointer never enters.
Future<TestGesture> _mouse(WidgetTester tester) async {
  final TestGesture gesture =
      await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  return gesture;
}

double _veilOpacity(WidgetTester tester) {
  return tester
      .widget<AnimatedOpacity>(
        find
            .descendant(
              of: find.byType(HoverArtworkVeil),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      )
      .opacity;
}

void main() {
  group('hover feedback', () {
    testWidgets('an album cover answers the pointer', (tester) async {
      await _pumpGrid(tester);
      expect(_veilOpacity(tester), 0);

      final TestGesture gesture = await _mouse(tester);
      await gesture.moveTo(tester.getCenter(find.byType(AlbumGridCard).first));
      await tester.pumpAndSettle();
      expect(_veilOpacity(tester), 1);

      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(_veilOpacity(tester), 0);
    });

    testWidgets('only the card under the pointer lights up', (tester) async {
      await _pumpGrid(tester);
      final TestGesture gesture = await _mouse(tester);
      await gesture.moveTo(tester.getCenter(find.byType(AlbumGridCard).first));
      await tester.pumpAndSettle();

      final Iterable<AnimatedOpacity> veils =
          tester.widgetList<AnimatedOpacity>(
        find.descendant(
          of: find.byType(HoverArtworkVeil),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(veils.where((AnimatedOpacity o) => o.opacity == 1), hasLength(1));
    });

    testWidgets('nothing hovers without a pointer', (tester) async {
      await _pumpGrid(tester);

      // A touch device never sends an enter event, so the grid looks exactly
      // as it did before any of this existed.
      expect(_veilOpacity(tester), 0);
      expect(tester.takeException(), isNull);
    });

    test('hover is distinct from selection, in both themes', () {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.dark(BrandPalettes.classic),
        AppTheme.light(BrandPalettes.classicLight),
      ]) {
        final Color hover = theme.hoverColor;
        final Color? selected = theme.listTileTheme.selectedTileColor;

        // Visible at all: Material's 4% default is close to invisible on a
        // black-first surface.
        expect(hover.a, greaterThan(0.05));
        // …and quiet enough to read as a hint rather than a state.
        expect(hover.a, lessThan(0.2));
        // Near-neutral, not the violet that means "selected": the channels
        // stay within a hair of each other, where the brand primary pulls them
        // far apart.
        expect(hover, isNot(selected));
        expect(hover.r, closeTo(hover.g, 0.06));
        expect(hover.g, closeTo(hover.b, 0.06));
      }
    });
  });
}
