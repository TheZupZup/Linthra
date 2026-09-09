import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/bulk_download_summary.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/bulk_downloader.dart';

import '../../features/downloads/fake_download_repository.dart';

Track _remote(String id) =>
    Track(id: id, title: 'Song $id', uri: 'jellyfin:$id', albumName: 'Album');

void main() {
  group('BulkDownloader', () {
    test('requests every track in the collection exactly once', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2'), _remote('3')],
      );

      expect(repository.requested,
          <String>['jellyfin:1', 'jellyfin:2', 'jellyfin:3']);
      expect(summary.total, 3);
      expect(summary.downloaded, 3);
      expect(summary.failed, 0);
      expect(summary.running, isFalse);
      expect(summary.completionMessage,
          'All 3 songs from “Album” are available offline.');
    });

    test('collapses a duplicated track to a single request', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Playlist',
        // The same song twice, as a hand-built playlist can easily hold.
        tracks: <Track>[_remote('1'), _remote('2'), _remote('1')],
      );

      expect(repository.requested, <String>['jellyfin:1', 'jellyfin:2']);
      expect(summary.total, 2);
      expect(summary.downloaded, 2);
    });

    test('keeps two providers\' same-id copies apart', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();

      await const BulkDownloader().run(
        repository: repository,
        label: 'Mixed',
        tracks: const <Track>[
          Track(id: '1', title: 'A', uri: 'jellyfin:1'),
          Track(id: '1', title: 'A', uri: 'plex:1'),
        ],
      );

      // Same catalog id, different providers: the provider-aware cache key keeps
      // them distinct, so both copies are requested.
      expect(repository.requested, <String>['jellyfin:1', 'plex:1']);
    });

    test('never re-requests a track that is already offline', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        alreadyDownloaded: <String>{
          CachedTrack.cacheKeyForTrack(_remote('1')),
        },
      );

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2')],
      );

      // The existing download is left completely alone: not re-fetched, and
      // never removed.
      expect(repository.requested, <String>['jellyfin:2']);
      expect(repository.removed, isEmpty);
      expect(summary.alreadyOffline, 1);
      expect(summary.downloaded, 1);
      expect(summary.offlineNow, 2);
    });

    test('does nothing at all when the whole collection is already offline',
        () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        alreadyDownloaded: <String>{
          CachedTrack.cacheKeyForTrack(_remote('1')),
          CachedTrack.cacheKeyForTrack(_remote('2')),
        },
      );

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2')],
      );

      expect(repository.requested, isEmpty);
      expect(summary.requested, 0);
      expect(summary.completionMessage,
          'Every song in “Album” is already available offline.');
    });

    test('one failing track does not stop the rest of the batch', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        failingUris: <String>{'jellyfin:2'},
      );

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2'), _remote('3')],
      );

      expect(repository.requested.length, 3);
      expect(summary.downloaded, 2);
      expect(summary.failed, 1);
      expect(
        summary.completionMessage,
        'Downloaded 2 of 3 songs from “Album”. 1 failed. Retry it from '
        'Downloads.',
      );
    });

    test('a track too large for the cache does not stop the rest', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        // One oversized track: the repository refuses it, but the smaller ones
        // after it still fit.
        tooLargeUris: <String>{'jellyfin:1'},
      );

      final BulkDownloadSummary summary = await const BulkDownloader(
        maxOutstanding: 1,
      ).run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2'), _remote('3')],
      );

      // Every track was still offered, and the two that fit are offline.
      expect(repository.requested,
          <String>['jellyfin:1', 'jellyfin:2', 'jellyfin:3']);
      expect(summary.downloaded, 2);
      expect(summary.cacheRefused, 1);
      expect(summary.outOfSpace, isFalse);
      expect(summary.failed, 0);
      expect(
        summary.completionMessage,
        'Downloaded 2 of 3 songs from “Album”. 1 was too large for the cache '
        'limit.',
      );
    });

    test('gives up once the cache refuses several tracks in a row', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        // Nothing fits from the second track on: a genuinely full cache.
        outOfSpaceAfter: 1,
      );

      final BulkDownloadSummary summary = await const BulkDownloader(
        maxOutstanding: 1,
      ).run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[
          _remote('1'),
          _remote('2'),
          _remote('3'),
          _remote('4'),
          _remote('5'),
          _remote('6'),
        ],
      );

      expect(summary.outOfSpace, isTrue);
      expect(summary.downloaded, 1);
      // One that fit, then the refusals it takes to be sure, and no more: the
      // rest are never fetched only to be thrown away.
      expect(
        repository.requested,
        <String>['jellyfin:1', 'jellyfin:2', 'jellyfin:3', 'jellyfin:4'],
      );
      expect(
        summary.completionMessage,
        'Downloaded 1 of 6 songs from “Album”. There is not enough cache space '
        'for the rest. Free up space or raise the cache limit in Settings.',
      );
    });

    test('queues the collection when the network policy says wait', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        outcomes: <String, DownloadRequestOutcome>{
          'jellyfin:1': DownloadRequestOutcome.waitingForWifi,
          'jellyfin:2': DownloadRequestOutcome.waitingForWifi,
        },
      );

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2')],
      );

      // Queued, not failed, and every track was still offered to the policy.
      expect(repository.requested.length, 2);
      expect(summary.waitingForNetwork, 2);
      expect(summary.failed, 0);
      expect(summary.downloaded, 0);
      expect(
        summary.completionMessage,
        contains('2 songs from “Album” are queued.'),
      );
      expect(
        summary.completionMessage,
        contains('Downloads are limited to Wi-Fi.'),
      );
    });

    test('being offline does not promise the batch will resume by itself',
        () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        outcomes: <String, DownloadRequestOutcome>{
          'jellyfin:1': DownloadRequestOutcome.waitingForConnection,
          'jellyfin:2': DownloadRequestOutcome.waitingForConnection,
        },
      );

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2')],
      );

      expect(
        summary.completionMessage,
        '2 songs from “Album” are queued. You\'re offline. Start them again '
        'from Downloads once you\'re back online.',
      );
      // Nothing here retries on a reconnect, so the batch must not say it will.
      expect(
        summary.completionMessage,
        isNot(contains('automatically')),
      );
    });

    test('a mid-batch network change queues the rest instead of failing it',
        () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        outcomes: <String, DownloadRequestOutcome>{
          'jellyfin:3': DownloadRequestOutcome.waitingForConnection,
        },
      );

      final BulkDownloadSummary summary = await const BulkDownloader(
        maxOutstanding: 1,
      ).run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2'), _remote('3')],
      );

      expect(summary.downloaded, 2);
      expect(summary.waitingForNetwork, 1);
      expect(summary.failed, 0);
      expect(
        summary.completionMessage,
        'Downloaded 2 of 3 songs from “Album”. 1 is queued for later.',
      );
    });

    test('stopping the batch requests nothing further', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      bool canceled = false;

      final BulkDownloadSummary summary = await const BulkDownloader(
        maxOutstanding: 1,
      ).run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[
          _remote('1'),
          _remote('2'),
          _remote('3'),
          _remote('4'),
        ],
        isCanceled: () => canceled,
        onProgress: (BulkDownloadSummary progress) {
          if (progress.completed == 2) canceled = true;
        },
      );

      expect(summary.canceled, isTrue);
      expect(repository.requested, <String>['jellyfin:1', 'jellyfin:2']);
      // Stopping never takes away what was already downloaded.
      expect(repository.removed, isEmpty);
      expect(summary.downloaded, 2);
      expect(
        summary.completionMessage,
        'Stopped. Downloaded 2 of 4 songs from “Album”.',
      );
    });

    test('keeps at most maxOutstanding requests in flight', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();

      await const BulkDownloader(maxOutstanding: 2).run(
        repository: repository,
        label: 'Playlist',
        tracks: <Track>[for (int i = 0; i < 12; i++) _remote('$i')],
      );

      expect(repository.peakConcurrency, lessThanOrEqualTo(2));
      expect(repository.requested.length, 12);
    });

    test('reports progress as it goes', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();
      final List<int> completed = <int>[];

      await const BulkDownloader(maxOutstanding: 1).run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2'), _remote('3')],
        onProgress: (BulkDownloadSummary progress) =>
            completed.add(progress.completed),
      );

      // An opening 0-of-3 so the UI can show the bar immediately, then one tick
      // per finished track.
      expect(completed, <int>[0, 1, 2, 3]);
    });

    test('says when the cache limit evicted earlier downloads', () async {
      final Track older = _remote('99');
      final FakeDownloadRepository repository = FakeDownloadRepository(
        alreadyDownloaded: <String>{CachedTrack.cacheKeyForTrack(older)},
        // Room for two tracks in total, so caching the second new one costs the
        // older download its place.
        maxCachedTracks: 2,
      );

      final BulkDownloadSummary summary = await const BulkDownloader(
        maxOutstanding: 1,
      ).run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2')],
      );

      expect(summary.downloaded, 2);
      expect(summary.evictedExisting, 1);
      expect(
        summary.completionMessage,
        'All 2 songs from “Album” are available offline. 1 earlier download was '
        'removed to stay under the cache limit.',
      );
    });

    test('does not count an evicted collection track as still offline',
        () async {
      final Track cached = _remote('1');
      final FakeDownloadRepository repository = FakeDownloadRepository(
        alreadyDownloaded: <String>{CachedTrack.cacheKeyForTrack(cached)},
        // Room for exactly one song, so downloading the second costs the first
        // its place even though both are in this collection.
        maxCachedTracks: 1,
      );

      final BulkDownloadSummary summary = await const BulkDownloader(
        maxOutstanding: 1,
      ).run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[cached, _remote('2')],
      );

      // One song is offline, not two: the summary reads the repository rather
      // than adding "was already there" to "just downloaded".
      expect(summary.offlineNow, 1);
      expect(summary.downloaded, 1);
      expect(summary.evictedExisting, 1);
      expect(
        summary.completionMessage,
        'Downloaded 1 of 2 songs from “Album”. 1 earlier download was removed '
        'to stay under the cache limit.',
      );
    });

    test('a track already downloading elsewhere is not called failed',
        () async {
      final FakeDownloadRepository repository = FakeDownloadRepository(
        // Started from the per-track action moments earlier: the repository
        // returns at once and the fetch is still running.
        inFlightElsewhereUris: <String>{'jellyfin:2'},
      );

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[_remote('1'), _remote('2')],
      );

      expect(summary.downloaded, 1);
      // Still downloading is not failed; the Downloads screen shows it live.
      expect(summary.failed, 0);
      expect(
          summary.completionMessage, 'Downloaded 1 of 2 songs from “Album”.');
    });

    test('an empty collection is a no-op', () async {
      final FakeDownloadRepository repository = FakeDownloadRepository();

      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: const <Track>[],
      );

      expect(repository.requested, isEmpty);
      expect(summary.total, 0);
      expect(summary.completionMessage, 'Nothing to download.');
    });
  });
}
