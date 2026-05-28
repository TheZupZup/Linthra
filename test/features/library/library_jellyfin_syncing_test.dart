import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import 'fake_music_library_repository.dart';

/// Holds the Jellyfin sync controller in a fixed state for the empty-state test.
class _FixedSyncController extends JellyfinSyncController {
  _FixedSyncController(this._fixed);
  final JellyfinSyncState _fixed;
  @override
  JellyfinSyncState build() => _fixed;
}

Future<void> _pumpLibrary(
  WidgetTester tester, {
  required JellyfinSyncState syncState,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        // An empty catalog — the case onboarding starts from.
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository()),
        jellyfinSyncControllerProvider
            .overrideWith(() => _FixedSyncController(syncState)),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  // Let the (empty) catalog load resolve. Don't pumpAndSettle: the syncing
  // state shows an endless progress spinner.
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Library empty state during a Jellyfin sync', () {
    testWidgets('reads as "syncing", not "no music", while a sync runs',
        (tester) async {
      await _pumpLibrary(tester, syncState: const JellyfinSyncState.syncing());

      expect(find.text('Your Jellyfin library is syncing'), findsOneWidget);
      expect(find.textContaining('This may take a moment'), findsOneWidget);
      // It must not look broken / empty.
      expect(find.text('No music folder selected'), findsNothing);
      expect(find.text('No music found'), findsNothing);
    });

    testWidgets('falls back to the normal empty state when not syncing',
        (tester) async {
      await _pumpLibrary(tester, syncState: const JellyfinSyncState());

      // No sync in flight, empty catalog → the usual folder-pick prompt.
      expect(find.text('Your Jellyfin library is syncing'), findsNothing);
      expect(find.text('No music folder selected'), findsOneWidget);
    });
  });
}
