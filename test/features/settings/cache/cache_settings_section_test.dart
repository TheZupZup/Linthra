import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/features/settings/cache/cache_settings_section.dart';

import '../../library/fake_remote_track_downloader.dart';

void main() {
  group('CacheSettingsSection', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final container = ProviderContainer(
        // Plugin-free defaults; only the remote downloader is faked so a
        // jellyfin: track counts as a managed download.
        overrides: [
          remoteTrackDownloaderProvider
              .overrideWithValue(FakeRemoteTrackDownloader()),
          connectivityServiceProvider.overrideWithValue(_FakeConnectivity()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: CacheSettingsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('shows usage against the default 4 GB limit', (tester) async {
      await pump(tester);

      expect(find.text('Offline cache'), findsOneWidget);
      expect(find.textContaining('of 4 GB used'), findsOneWidget);
      expect(find.textContaining('0 B of'), findsOneWidget);
    });

    testWidgets('changing the limit updates the displayed maximum', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.text('Change limit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('8 GB'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('of 8 GB used'), findsOneWidget);
    });

    testWidgets('clear all empties the cache', (tester) async {
      final container = await pump(tester);

      // A download so there's something to clear (Clear cache is disabled when
      // the cache is empty).
      await container.read(downloadRepositoryProvider).requestDownload(
            const Track(id: 'j1', title: 'Song', uri: 'jellyfin:j1'),
          );
      await tester.pumpAndSettle();
      expect(find.textContaining('4 B of'), findsOneWidget);

      await tester.tap(find.text('Clear cache'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(find.textContaining('0 B of'), findsOneWidget);
    });
  });
}

class _FakeConnectivity implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}
