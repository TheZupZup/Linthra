import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/downloads/downloads_screen.dart';

import '../library/fake_music_library_repository.dart';

void main() {
  group('DownloadsScreen', () {
    Future<void> pump(WidgetTester tester, FakeMusicLibraryRepository repo) {
      return tester.pumpWidget(
        ProviderScope(
          // Download stores are plugin-free in tests; connectivity is faked so
          // the production platform channel is not touched.
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(repo),
            connectivityServiceProvider.overrideWithValue(
              _FakeConnectivity(NetworkStatus.wifi),
            ),
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

  group('DownloadsScreen in-progress section', () {
    const track = Track(id: 'r1', title: 'Remote Song', uri: 'jellyfin:r1');

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required RemoteTrackDownloader downloader,
      bool allowMobileData = false,
      NetworkStatus connectivity = NetworkStatus.wifi,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicLibraryRepositoryProvider.overrideWithValue(
              FakeMusicLibraryRepository(tracks: const <Track>[track]),
            ),
            remoteTrackDownloaderProvider.overrideWithValue(downloader),
            downloadPreferencesProvider.overrideWithValue(
              InMemoryDownloadPreferences(allowMobileData: allowMobileData),
            ),
            connectivityServiceProvider
                .overrideWithValue(_FakeConnectivity(connectivity)),
          ],
          child: const MaterialApp(home: DownloadsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(DownloadsScreen)),
      );
    }

    testWidgets(
        'shows a downloading track with progress, then moves it to '
        'the finished list when it completes', (tester) async {
      final gate = Completer<void>();
      final container = await pump(tester,
          downloader: _FakeRemoteDownloader(gate: gate.future));

      // Start the download; it parks on the gate, so it is in flight. The bar
      // is determinate, so pumpAndSettle returns (it never awaits the gate).
      unawaited(
          container.read(downloadRepositoryProvider).requestDownload(track));
      await tester.pumpAndSettle();

      // It appears in the in-progress section with a live, determinate bar.
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(find.textContaining('Downloading'), findsOneWidget);
      expect(find.textContaining('50%'), findsOneWidget);
      expect(find.byTooltip('Cancel download'), findsOneWidget);
      // The cache-usage bar plus the row's own progress bar.
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

      // Letting it finish moves it out of "In progress" into the finished list.
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('In progress'), findsNothing);
      expect(find.textContaining('Downloading'), findsNothing);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(find.byTooltip('Remove download'), findsOneWidget);
    });

    testWidgets('a failed download offers Retry, which re-runs it', (
      tester,
    ) async {
      final downloader = _FakeRemoteDownloader(error: Exception('boom'));
      final container = await pump(tester, downloader: downloader);

      await container.read(downloadRepositoryProvider).requestDownload(track);
      await tester.pumpAndSettle();

      expect(find.text('Download failed'), findsOneWidget);
      expect(find.byTooltip('Retry download'), findsOneWidget);

      // Clear the fault and retry from the row: it reaches the finished list.
      downloader.error = null;
      await tester.tap(find.byTooltip('Retry download'));
      await tester.pumpAndSettle();

      expect(find.text('Download failed'), findsNothing);
      expect(find.text('In progress'), findsNothing);
      expect(find.byTooltip('Remove download'), findsOneWidget);
    });

    testWidgets('shows a queued track when mobile data is not allowed', (
      tester,
    ) async {
      final container = await pump(
        tester,
        downloader: _FakeRemoteDownloader(),
        // Default: mobile data not allowed, so on mobile the download queues.
        connectivity: NetworkStatus.mobile,
      );

      await container.read(downloadRepositoryProvider).requestDownload(track);
      await tester.pumpAndSettle();

      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Queued — waiting for Wi‑Fi'), findsOneWidget);
      expect(find.byTooltip('Cancel download'), findsOneWidget);
    });
  });
}

/// A connectivity stand-in reporting a fixed status, so the mobile-data gate
/// can be driven without a plugin.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity(this._status);

  final NetworkStatus _status;

  @override
  Stream<NetworkStatus> get statusStream =>
      Stream<NetworkStatus>.value(_status);

  @override
  Future<NetworkStatus> currentStatus() async => _status;
}

/// A remote downloader fake: treats `jellyfin:` tracks as remote and reports
/// half-progress (2 of 4 bytes) before returning canned bytes. A [gate] holds
/// the fetch in flight; a mutable [error] fails the attempt so a retry can be
/// exercised.
class _FakeRemoteDownloader implements RemoteTrackDownloader {
  _FakeRemoteDownloader({this.gate, this.error});

  final Future<void>? gate;
  Object? error;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackDownload> open(Track track) async {
    final Object? err = error;
    if (err != null) throw err;
    return RemoteTrackDownload(
      chunks: _chunks(),
      contentLength: 4,
      fileExtension: 'mp3',
    );
  }

  Stream<List<int>> _chunks() async* {
    yield <int>[1, 2];
    final Future<void>? pending = gate;
    if (pending != null) await pending;
    yield <int>[3, 4];
  }
}
