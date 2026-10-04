import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../library/fake_music_library_repository.dart';
import '../library/fake_remote_track_downloader.dart';
import '../player/fake_playback_controller.dart';

/// The per-track offline actions now live behind the trailing 3-dots overflow
/// menu (the dedicated download button was removed). These tests open that menu
/// and verify the context-aware, source-aware action set.
void main() {
  group('Library overflow download actions', () {
    Future<void> pump(WidgetTester tester, List<Track> tracks) async {
      await tester.pumpWidget(
        ProviderScope(
          // Keep the widget test independent from Android platform channels: the
          // fake downloader supplies bytes and the fixed unmetered connection lets
          // the request exercise the successful download path deterministically.
          // Removing an offline copy asks the player what is playing, so a fake
          // one keeps the host's real audio engine out of the test as well.
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              FakeMusicLibraryRepository(tracks: tracks),
            ),
            remoteTrackDownloaderProvider
                .overrideWithValue(FakeRemoteTrackDownloader()),
            connectivityServiceProvider.overrideWithValue(
              const _UnmeteredConnectivity(),
            ),
            playbackControllerProvider
                .overrideWithValue(FakePlaybackController()),
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

    // The list can rebuild a row while its confirmation is up (a library
    // reload, the phone turned sideways, a shorter window). The removal the
    // listener confirmed must still happen.
    testWidgets('Remove offline copy confirmed after the row was rebuilt', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      await pump(tester, <Track>[
        for (int i = 0; i < 16; i++)
          Track(
            id: '$i',
            title: 'Song ${i.toString().padLeft(2, '0')}',
            uri: 'jellyfin:$i',
          ),
      ]);
      final Finder menu = find.descendant(
        of: find.ancestor(
          of: find.text('Song 09'),
          matching: find.byType(TrackTile),
        ),
        matching: find.byTooltip('More actions'),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download for offline'));
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove offline copy'));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(915, 412);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Removed offline copy for 1 song.'), findsOneWidget);
    });
  });
}

class _UnmeteredConnectivity implements ConnectivityService {
  const _UnmeteredConnectivity();

  @override
  Stream<NetworkStatus> get statusStream =>
      Stream<NetworkStatus>.value(NetworkStatus.wifi);

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}
