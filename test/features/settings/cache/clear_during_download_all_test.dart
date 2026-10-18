// Freeing storage while "Download all" runs stops the batch.
//
// Settings > Free up storage only cleared the cache; the running batch was
// never told, so its worker went on requesting the tracks it had not reached
// and refilled what the user had just freed. Its summary then counted the
// downloads the clear took (a pinned one included) as removed "to stay under
// the cache limit".
//
// The card is driven with a batch parked mid-run, so the test reads exactly
// what the clear tells it; the batch itself runs for real in the last tests.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/bulk_download_summary.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/bulk_downloader.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/features/downloads/bulk_download_controller.dart';
import 'package:linthra/features/settings/cache/cache_settings_section.dart';

class _OnWifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Holds each fetch, once [holding], until the test releases it.
class _HeldFetches implements RemoteTrackDownloader {
  final List<String> fetched = <String>[];
  final List<Completer<void>> _held = <Completer<void>>[];
  bool holding = false;

  void releaseAll() {
    holding = false;
    for (final Completer<void> held in _held) {
      if (!held.isCompleted) held.complete();
    }
  }

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetched.add(track.id);
    if (holding) {
      final Completer<void> held = Completer<void>();
      _held.add(held);
      await held.future;
    }
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

/// A batch that stays running until [finish], and keeps the controller's
/// stop check for the test to read.
class _ParkedBatch extends BulkDownloader {
  _ParkedBatch();

  bool Function()? isCanceled;
  final Completer<BulkDownloadSummary> _done = Completer<BulkDownloadSummary>();

  void finish(BulkDownloadSummary summary) => _done.complete(summary);

  @override
  Future<BulkDownloadSummary> run({
    required DownloadRepository repository,
    required String label,
    required List<Track> tracks,
    bool Function()? isCanceled,
    void Function(BulkDownloadSummary progress)? onProgress,
  }) {
    this.isCanceled = isCanceled;
    onProgress?.call(
      BulkDownloadSummary(label: label, total: tracks.length, running: true),
    );
    return _done.future;
  }
}

const Track _earlier = Track(id: 'old', title: 'Old', uri: 'jellyfin:old');

const List<Track> _album = <Track>[
  Track(id: '1', title: 'One', uri: 'jellyfin:1'),
  Track(id: '2', title: 'Two', uri: 'jellyfin:2'),
  Track(id: '3', title: 'Three', uri: 'jellyfin:3'),
];

ProviderContainer _container({
  required RemoteTrackDownloader downloader,
  BulkDownloader batch = const BulkDownloader(maxOutstanding: 1),
  int? maxCacheBytes,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      remoteTrackDownloaderProvider.overrideWithValue(downloader),
      connectivityServiceProvider.overrideWithValue(_OnWifi()),
      bulkDownloaderProvider.overrideWithValue(batch),
      if (maxCacheBytes != null)
        downloadPreferencesProvider.overrideWithValue(
          InMemoryDownloadPreferences(maxCacheBytes: maxCacheBytes),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  for (final String clear in <String>[
    'Clear offline downloads',
    'Clear cache',
  ]) {
    testWidgets('"$clear" stops a running Download all', (tester) async {
      final _ParkedBatch batch = _ParkedBatch();
      final ProviderContainer container = _container(
        downloader: _HeldFetches(),
        batch: batch,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: CacheSettingsSection()),
          ),
        ),
      );
      // Something to clear, so the card offers to.
      await container
          .read(downloadRepositoryProvider)
          .requestDownload(_earlier);
      await tester.pumpAndSettle();

      BulkDownloadSummary? summary;
      unawaited(container
          .read(bulkDownloadControllerProvider.notifier)
          .start(label: 'Road Trip', tracks: _album)
          .then((BulkDownloadSummary? done) => summary = done));
      await tester.pump();
      expect(batch.isCanceled!(), isFalse);

      await tester.tap(find.text('Free up storage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(clear));
      await tester.pumpAndSettle();

      expect(batch.isCanceled!(), isTrue,
          reason: 'the batch was not told about the clear');

      // However it counted the copies gone since it started, none was the
      // cache limit's doing.
      batch.finish(const BulkDownloadSummary(
        label: 'Road Trip',
        total: 3,
        completed: 1,
        evictedExisting: 1,
        canceled: true,
      ));
      await tester.pumpAndSettle();
      expect(summary?.evictedExisting, 0,
          reason: 'summary: ${summary?.completionMessage}');
    });
  }

  test('a stopped batch requests nothing more, and the cache stays clear',
      () async {
    // What the card does, with the real batch and repository.
    final _HeldFetches fetches = _HeldFetches();
    final ProviderContainer container = _container(downloader: fetches);
    await container.read(downloadRepositoryProvider).requestDownload(_earlier);

    fetches.holding = true;
    final Future<BulkDownloadSummary?> batch = container
        .read(bulkDownloadControllerProvider.notifier)
        .start(label: 'Road Trip', tracks: _album);
    await pumpEventQueue();
    expect(fetches.fetched, <String>['old', '1']);

    container.read(bulkDownloadControllerProvider.notifier).stopForClear();
    await container.read(offlineCacheManagerProvider).clearAll();
    fetches.releaseAll();
    final BulkDownloadSummary? summary = await batch;

    expect(fetches.fetched, <String>['old', '1']);
    expect(
      await container.read(downloadRepositoryProvider).downloadedTrackKeys(),
      isEmpty,
    );
    expect(summary?.canceled, isTrue);
    expect(summary?.evictedExisting, 0);
  });

  test('a batch the cache limit made room for still says so', () async {
    // Only a clear zeroes the count: a real eviction is still reported.
    final ProviderContainer container = _container(
      downloader: _HeldFetches(),
      // Room for two 4-byte copies.
      maxCacheBytes: 8,
    );
    await container.read(downloadRepositoryProvider).requestDownload(_earlier);

    final BulkDownloadSummary? summary = await container
        .read(bulkDownloadControllerProvider.notifier)
        .start(label: 'Road Trip', tracks: _album.take(2).toList());

    expect(summary?.evictedExisting, 1);
  });
}
