import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/bulk_download_summary.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/bulk_downloader.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

/// A connectivity stand-in whose reported status the test can flip at will.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity(this.status);

  NetworkStatus status;

  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// One fetch held until the test settles it.
class _HeldFetch {
  _HeldFetch(this.track);

  final Track track;
  final Completer<void> gate = Completer<void>();
}

/// A remote downloader whose every fetch waits on its own [_HeldFetch], in
/// call order, and records which network the fetch started on.
class _HeldDownloader implements RemoteTrackDownloader {
  _HeldDownloader(this._connectivity);

  final _FakeConnectivity _connectivity;
  final List<_HeldFetch> calls = <_HeldFetch>[];

  /// The network each fetch started on, by track id.
  final Map<String, NetworkStatus> startedOn = <String, NetworkStatus>{};

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    startedOn[track.id] = _connectivity.status;
    final _HeldFetch held = _HeldFetch(track);
    calls.add(held);
    await held.gate.future;
    onProgress?.call(4, 4);
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('network policy for downloads waiting for a slot', () {
    // Wired as in the app: the default scheduler (three downloads fetch at
    // once, the rest wait for a slot), "Wi-Fi only" (the default profile),
    // and a live network-change stream (Android's channel, or the network
    // monitor portal on Linux).
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _HeldDownloader downloader;
    late StreamController<NetworkStatus> changes;

    CacheDownloadRepository build() {
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
        networkChanges: changes.stream,
      );
    }

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      preferences = InMemoryDownloadPreferences();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      downloader = _HeldDownloader(connectivity);
      changes = StreamController<NetworkStatus>.broadcast();
    });

    tearDown(() => changes.close());

    Future<void> networkBecomes(NetworkStatus status) async {
      connectivity.status = status;
      changes.add(status);
      await _pumpUntil(() => false);
    }

    /// Lets every fetch started so far finish.
    Future<void> finishStartedFetches() async {
      for (final _HeldFetch call in downloader.calls) {
        if (!call.gate.isCompleted) call.gate.complete();
      }
      await _pumpUntil(() => false);
    }

    /// The downloads that pulled their bytes over a network "Wi-Fi only"
    /// does not allow.
    Iterable<String> fetchedOffWifi() => downloader.startedOn.entries
        .where((MapEntry<String, NetworkStatus> e) =>
            e.value != NetworkStatus.wifi)
        .map((MapEntry<String, NetworkStatus> e) => e.key);

    test(
        'a song still waiting for a slot when Wi-Fi is lost is not fetched '
        'over mobile data', () async {
      final CacheDownloadRepository repository = build();

      // On Wi-Fi the listener taps Download on four songs: three fetch, the
      // fourth waits for a slot.
      final List<Future<DownloadRequestOutcome>> requests =
          <Future<DownloadRequestOutcome>>[
        for (final String id in <String>['a', 'b', 'c', 'd'])
          repository.requestDownload(_jellyfin(id)),
      ];
      await _pumpUntil(() => downloader.calls.length >= 3);
      expect(downloader.calls.map((c) => c.track.id), <String>['a', 'b', 'c']);
      expect(await repository.statusFor('d'), DownloadStatus.queued);

      // They walk out of Wi-Fi range: now on metered mobile data.
      await networkBecomes(NetworkStatus.mobile);
      await finishStartedFetches();

      // d must wait for Wi-Fi, still queued, like a download asked for now.
      expect(fetchedOffWifi(), isEmpty);
      expect(await repository.statusFor('d'), DownloadStatus.queued);

      // Back on Wi-Fi it starts by itself.
      await networkBecomes(NetworkStatus.wifi);
      await finishStartedFetches();
      await Future.wait(requests);
      expect(await repository.statusFor('d'), DownloadStatus.downloaded);
      expect(fetchedOffWifi(), isEmpty);
    });

    test(
        'an album held for Wi-Fi and released by it stops when Wi-Fi is '
        'lost again', () async {
      // "Download all" on mobile data: every song is held for Wi-Fi.
      connectivity.status = NetworkStatus.mobile;
      final CacheDownloadRepository repository = build();
      final BulkDownloadSummary summary = await const BulkDownloader().run(
        repository: repository,
        label: 'Album',
        tracks: <Track>[
          for (final String id in <String>['a', 'b', 'c', 'd', 'e'])
            _jellyfin(id),
        ],
      );
      expect(summary.waitingForNetwork, 5);
      expect(downloader.calls, isEmpty);

      // Home Wi-Fi: all five are asked again; three take the slots.
      await networkBecomes(NetworkStatus.wifi);
      expect(downloader.calls, hasLength(3));

      // Out of range again before the album is done.
      await networkBecomes(NetworkStatus.mobile);
      await finishStartedFetches();

      // The two still waiting must not pull a byte over mobile data.
      expect(fetchedOffWifi(), isEmpty);
      for (final String id in <String>['d', 'e']) {
        expect(await repository.statusFor(id), DownloadStatus.queued);
      }
      await finishStartedFetches();
    });

    test(
        'switching back to "Wi-Fi only" on mobile data stops songs still '
        'waiting for a slot', () async {
      // On mobile data with mobile downloads allowed.
      connectivity.status = NetworkStatus.mobile;
      await preferences.setMobileDataProfile(MobileDataProfile.unlimited);
      final CacheDownloadRepository repository = build();
      for (final String id in <String>['a', 'b', 'c', 'd']) {
        unawaited(repository.requestDownload(_jellyfin(id)));
      }
      await _pumpUntil(() => downloader.calls.length >= 3);

      // The listener changes their mind: Settings, "Wi-Fi only".
      await preferences.setMobileDataProfile(MobileDataProfile.wifiOnly);
      await repository.retryHeldDownloads();
      await finishStartedFetches();

      // a, b and c were already fetching; d had not started and must wait.
      expect(downloader.startedOn.containsKey('d'), isFalse);
      expect(await repository.statusFor('d'), DownloadStatus.queued);
      await finishStartedFetches();
    });
  });
}
