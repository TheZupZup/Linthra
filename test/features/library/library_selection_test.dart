import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';

import 'fake_music_library_repository.dart';
import 'fake_remote_track_downloader.dart';

const List<Track> _mixed = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'jellyfin:b'),
];

// Two unrelated songs that share a bare server-side id across providers.
const List<Track> _sameBareId = <Track>[
  Track(id: '101', title: 'Alpha', uri: 'jellyfin:101'),
  Track(id: '101', title: 'Beta', uri: 'subsonic:101'),
];

Future<FakeMusicLibraryRepository> _pump(
  WidgetTester tester, {
  List<Track> tracks = _mixed,
}) async {
  final FakeMusicLibraryRepository repository =
      FakeMusicLibraryRepository(tracks: tracks);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(repository),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  group('Library multi-select', () {
    testWidgets('long-press enters selection mode and shows the count',
        (tester) async {
      await _pump(tester);

      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Song B'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets(
        'same bare-id rows from different providers select independently',
        (tester) async {
      await _pump(tester, tracks: _sameBareId);

      // Long-press one of the two same-id rows: only it is selected, because
      // selection keys on the provider-namespaced uri, not the bare id.
      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('2 selected'), findsNothing);
    });

    testWidgets('offers safe actions and hides unsafe destructive deletes',
        (tester) async {
      await _pump(tester);
      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song B'));
      await tester.pumpAndSettle();

      // Safe, reversible actions are offered.
      expect(find.byTooltip('Add to playlist'), findsOneWidget);
      expect(find.byTooltip('Remove from Linthra'), findsOneWidget);
      // The Jellyfin track in the selection means offline-copy removal applies.
      expect(find.byTooltip('Remove offline copies'), findsOneWidget);
      // Destructive file/server deletes are never offered in this release.
      expect(find.byTooltip('Delete from server'), findsNothing);
      expect(find.byTooltip('Delete files'), findsNothing);
    });

    testWidgets('a local-only selection hides the offline-copy action',
        (tester) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
        ],
      );
      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove from Linthra'), findsOneWidget);
      expect(find.byTooltip('Remove offline copies'), findsNothing);
    });

    testWidgets('bulk remove asks for confirmation showing the count',
        (tester) async {
      final FakeMusicLibraryRepository repository = await _pump(tester);
      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song B'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove from Linthra'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Remove 2 songs from Linthra?'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Remove'), findsOneWidget);

      // Confirming removes only from the index (the fake records the uris — the
      // catalog's provider-namespaced identity, not the bare id).
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(
        repository.removedTrackUris,
        containsAll(<String>['file:///a.mp3', 'jellyfin:b']),
      );
    });
  });
}
