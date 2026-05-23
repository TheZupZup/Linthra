import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/data/repositories/music_library_repository_provider.dart';
import 'package:sonara/features/library/library_screen.dart';

import '../library/fake_music_library_repository.dart';

void main() {
  group('Library download action', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          // Default download providers are plugin-free (in-memory store +
          // optimistic connectivity), so the row action works without overrides.
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              FakeMusicLibraryRepository(
                tracks: const <Track>[
                  Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
                ],
              ),
            ),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a not-downloaded row offers a download action', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byTooltip('Download'), findsOneWidget);
      expect(find.byTooltip('Remove download'), findsNothing);
    });

    testWidgets('downloading then removing toggles the row action', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove download'), findsOneWidget);
      expect(find.byTooltip('Download'), findsNothing);

      await tester.tap(find.byTooltip('Remove download'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Download'), findsOneWidget);
      expect(find.byTooltip('Remove download'), findsNothing);
    });
  });
}
