import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';

import '../library/fake_music_library_repository.dart';
import '../library/fake_remote_track_downloader.dart';

/// The per-track offline actions now live behind the trailing 3-dots overflow
/// menu (the dedicated download button was removed). These tests open that menu
/// and verify the context-aware, source-aware action set.
void main() {
  group('Library overflow download actions', () {
    Future<void> pump(WidgetTester tester, List<Track> tracks) async {
      await tester.pumpWidget(
        ProviderScope(
          // Default download providers are plugin-free (in-memory store); the
          // remote downloader is faked so a `jellyfin:` track counts as
          // remote/offline-capable, and connectivity is faked to Wi-Fi so the
          // network policy lets the download proceed (the production default
          // fails closed without the platform channel).
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              FakeMusicLibraryRepository(tracks: tracks),
            ),
            remoteTrackDownloaderProvider
                .overrideWithValue(FakeRemoteTrackDownloader()),
            connectivityServiceProvider
                .overrideWithValue(const _FakeConnectivity()),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
    }

    testWidgets('a remote track offers Download for offline', (tester) async {
      await pump(tester, const <Track>[
        Track(id: '1', title: 'Remote Song', uri: 'jellyfin:1'),
      ]);

      await openMenu(tester);
      expect(find.text('Download for offline'), findsOneWidget);
      expect(find.text('Remove offline copy'), findsNothing);
      expect(find.text('Play next'), findsOneWidget);
    });

    testWidgets('downloading a remote track flips to Remove offline copy', (
      tester,
    ) async {
      await pump(tester, const <Track>[
        Track(id: '1', title: 'Remote Song', uri: 'jellyfin:1'),
      ]);

      await openMenu(tester);
      await tester.tap(find.text('Download for offline'));
      await tester.pumpAndSettle();

      await openMenu(tester);
      expect(find.text('Remove offline copy'), findsOneWidget);
      expect(find.text('Download for offline'), findsNothing);

      // The subtle downloaded glyph is now visible on the row.
      expect(find.byIcon(Icons.download_done), findsOneWidget);
    });

    testWidgets('a local track exposes no remote-download actions', (
      tester,
    ) async {
      await pump(tester, const <Track>[
        Track(id: '1', title: 'Local Song', uri: 'file:///s1.mp3'),
      ]);

      await openMenu(tester);
      expect(find.text('Download for offline'), findsNothing);
      expect(find.text('Remove offline copy'), findsNothing);
      // Only the queue action remains for local files.
      expect(find.text('Play next'), findsOneWidget);
    });
  });
}

/// A connectivity stand-in reporting Wi-Fi so the download policy allows
/// downloads without the platform channel.
class _FakeConnectivity implements ConnectivityService {
  const _FakeConnectivity();

  @override
  Stream<NetworkStatus> get statusStream =>
      Stream<NetworkStatus>.value(NetworkStatus.wifi);

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}
