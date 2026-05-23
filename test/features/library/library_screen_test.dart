import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/data/repositories/music_library_repository_provider.dart';
import 'package:sonara/features/library/library_screen.dart';

import 'fake_music_library_repository.dart';

Future<void> _pumpScreen(
  WidgetTester tester,
  FakeMusicLibraryRepository repository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        musicLibraryRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
}

void main() {
  group('LibraryScreen', () {
    testWidgets('shows a spinner while loading', (tester) async {
      await _pumpScreen(tester, FakeMusicLibraryRepository());

      // Before the async load settles, the loading indicator is visible.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();
    });

    testWidgets('shows the empty state when there are no tracks', (
      tester,
    ) async {
      await _pumpScreen(tester, FakeMusicLibraryRepository());
      await tester.pumpAndSettle();

      expect(find.text('Your library is empty'), findsOneWidget);
    });

    testWidgets('lists tracks with title and subtitle', (tester) async {
      await _pumpScreen(
        tester,
        FakeMusicLibraryRepository(
          tracks: <Track>[
            const Track(
              id: '1',
              title: 'Song One',
              uri: 'file:///song1.mp3',
              artistName: 'Artist A',
              albumName: 'Album X',
            ),
            const Track(id: '2', title: 'Song Two', uri: 'file:///song2.mp3'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A • Album X'), findsOneWidget);
      // No metadata: falls back to the uri/path.
      expect(find.text('Song Two'), findsOneWidget);
      expect(find.text('file:///song2.mp3'), findsOneWidget);
    });

    testWidgets('shows an error state with a retry action', (tester) async {
      await _pumpScreen(
        tester,
        FakeMusicLibraryRepository(error: Exception('disk on fire')),
      );
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load your library"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
