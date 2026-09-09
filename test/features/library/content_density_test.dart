import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/features/library/widgets/artist_grid.dart';
import 'package:linthra/features/library/widgets/artist_tile.dart';

/// Desktop density (#384): a Linux window fits materially more of a library per
/// screen, and a phone's rows do not move a pixel. The signal is the platform,
/// not the width — an Android tablet in landscape is as wide as a desktop window
/// and still driven by a thumb.
final List<Artist> _artists = <Artist>[
  for (int i = 0; i < 12; i++)
    Artist(id: '$i', name: 'Artist $i', albumCount: 2, trackCount: 9),
];

/// The row height a touch layout has always had: a two-line ListTile.
const double _touchRowHeight = 72;

ThemeData _theme() => AppTheme.dark(BrandPalettes.classic);

/// Runs [body] as if Linthra were on [platform].
///
/// The override has to be cleared inside the test body rather than in a
/// tearDown: the framework asserts that no foundation debug variable is still
/// set when the body returns.
Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _pumpArtists(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: _theme(),
        home: Scaffold(
          body: ArtistGrid(artists: _artists, onOpen: (_) {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _rowHeight(WidgetTester tester) =>
    tester.getRect(find.byType(ArtistTile).first).height;

void main() {
  group('content density', () {
    test('the theme is compact on a desktop host and standard on a phone', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(_theme().visualDensity, VisualDensity.compact);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(_theme().visualDensity, VisualDensity.standard);
    });

    testWidgets('a wide touch window keeps the row height it always had',
        (tester) async {
      await _onPlatform(TargetPlatform.android, () async {
        await _pumpArtists(tester);
        expect(_rowHeight(tester), _touchRowHeight);
      });
    });

    testWidgets('a desktop host fits more rows in the same window',
        (tester) async {
      await _onPlatform(TargetPlatform.linux, () async {
        await _pumpArtists(tester);

        final double height = _rowHeight(tester);
        expect(height, lessThan(_touchRowHeight));
        // Density buys back padding, never the row: still clickable.
        expect(height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('a row control stays a real click target when compact',
        (tester) async {
      await _onPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: _theme(),
              home: Scaffold(
                body: ListTile(
                  title: const Text('Song One'),
                  trailing: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final Size button = tester.getSize(find.byType(IconButton));
        expect(button.width, greaterThanOrEqualTo(40));
        expect(button.height, greaterThanOrEqualTo(40));
      });
    });
  });
}
