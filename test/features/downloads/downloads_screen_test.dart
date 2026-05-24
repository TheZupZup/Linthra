import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/downloads/downloads_screen.dart';

import '../library/fake_music_library_repository.dart';

void main() {
  group('DownloadsScreen', () {
    Future<void> pump(WidgetTester tester, FakeMusicLibraryRepository repo) {
      return tester.pumpWidget(
        ProviderScope(
          // Default download providers are plugin-free (in-memory store +
          // optimistic connectivity), so the screen works without overrides.
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: DownloadsScreen()),
        ),
      );
    }

    testWidgets('shows the empty state when nothing is downloaded', (
      tester,
    ) async {
      await pump(tester, FakeMusicLibraryRepository());
      await tester.pumpAndSettle();

      expect(find.text('Nothing downloaded'), findsOneWidget);
    });

    testWidgets('shows a friendly, leak-free error when the library throws', (
      tester,
    ) async {
      await pump(
        tester,
        FakeMusicLibraryRepository(
          error: Exception('FileSystemException: /data/.../db errno = 13'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load downloads"), findsOneWidget);
      // The raw exception text must never reach the UI.
      expect(find.textContaining('errno'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
    });

    testWidgets('removing a download drops it from the list', (tester) async {
      const track = Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3');
      await pump(
        tester,
        FakeMusicLibraryRepository(tracks: const <Track>[track]),
      );
      await tester.pumpAndSettle();

      // Mark the on-device track as downloaded so it appears in the list.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DownloadsScreen)),
      );
      await container.read(downloadRepositoryProvider).requestDownload(track);
      await tester.pumpAndSettle();
      expect(find.text('Song One'), findsOneWidget);

      // Removing it must update the UI state: the row disappears.
      await tester.tap(find.byTooltip('Remove download'));
      await tester.pumpAndSettle();
      expect(find.text('Song One'), findsNothing);
      expect(find.text('Nothing downloaded'), findsOneWidget);
    });
  });
}
