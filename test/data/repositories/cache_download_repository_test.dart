import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/repositories/download_repository.dart';
import 'package:sonara/core/services/connectivity_service.dart';
import 'package:sonara/data/repositories/cache_download_repository.dart';
import 'package:sonara/data/repositories/in_memory_download_preferences.dart';
import 'package:sonara/data/repositories/in_memory_download_store.dart';

/// A connectivity stand-in whose reported status the test can flip at will.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity(this.status);

  NetworkStatus status;

  @override
  Stream<NetworkStatus> get statusStream => Stream<NetworkStatus>.value(status);

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

void main() {
  group('CacheDownloadRepository', () {
    late InMemoryDownloadStore store;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;

    CacheDownloadRepository build() {
      return CacheDownloadRepository(
        store: store,
        connectivity: connectivity,
        preferences: preferences,
      );
    }

    setUp(() {
      store = InMemoryDownloadStore();
      preferences = InMemoryDownloadPreferences();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
    });

    test('tracks start not downloaded', () async {
      final repository = build();
      expect(await repository.statusFor('a'), DownloadStatus.notDownloaded);
      expect(await repository.downloadedTrackIds(), isEmpty);
    });

    test('requestDownload marks a track downloaded and persists it', () async {
      final repository = build();

      await repository.requestDownload('a');

      expect(await repository.statusFor('a'), DownloadStatus.downloaded);
      expect(await repository.downloadedTrackIds(), <String>['a']);
      expect(await store.loadDownloadedIds(), <String>{'a'});
    });

    test('removeDownload reverts status and clears persistence', () async {
      final repository = build();
      await repository.requestDownload('a');

      await repository.removeDownload('a');

      expect(await repository.statusFor('a'), DownloadStatus.notDownloaded);
      expect(await repository.downloadedTrackIds(), isEmpty);
      expect(await store.loadDownloadedIds(), isEmpty);
    });

    test('downloaded IDs are reloaded from the store by a fresh repository',
        () async {
      await build().requestDownload('a');

      // A new repository over the same store reflects the persisted state.
      final reopened = build();
      expect(await reopened.statusFor('a'), DownloadStatus.downloaded);
      expect(await reopened.downloadedTrackIds(), <String>['a']);
    });

    test('statusStream seeds the current snapshot then emits changes',
        () async {
      await build().requestDownload('a');
      final repository = build();

      final emissions = <Map<String, DownloadStatus>>[];
      final sub = repository.statusStream.listen(emissions.add);
      await _settle();

      // Seeded with the persisted snapshot.
      expect(emissions.first, <String, DownloadStatus>{
        'a': DownloadStatus.downloaded,
      });

      await repository.requestDownload('b');
      await _settle();

      expect(emissions.last['b'], DownloadStatus.downloaded);
      await sub.cancel();
    });

    test('a downloaded track is not re-downloaded', () async {
      final repository = build();
      await repository.requestDownload('a');

      final emissions = <Map<String, DownloadStatus>>[];
      final sub = repository.statusStream.listen(emissions.add);
      await _settle();
      emissions.clear();

      await repository.requestDownload('a');
      await _settle();

      // No further status changes were emitted.
      expect(emissions, isEmpty);
      await sub.cancel();
    });

    group('Wi-Fi only policy', () {
      test('queues instead of downloading when on mobile', () async {
        await preferences.setWifiOnly(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.requestDownload('a');

        expect(await repository.statusFor('a'), DownloadStatus.queued);
        expect(await repository.downloadedTrackIds(), isEmpty);
        expect(await store.loadDownloadedIds(), isEmpty);
      });

      test('downloads when on Wi-Fi', () async {
        await preferences.setWifiOnly(true);
        connectivity.status = NetworkStatus.wifi;
        final repository = build();

        await repository.requestDownload('a');

        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
      });

      test('downloads over mobile when the preference is off', () async {
        await preferences.setWifiOnly(false);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.requestDownload('a');

        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
      });

      test('a queued track downloads on an explicit retry once on Wi-Fi',
          () async {
        await preferences.setWifiOnly(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();
        await repository.requestDownload('a');
        expect(await repository.statusFor('a'), DownloadStatus.queued);

        connectivity.status = NetworkStatus.wifi;
        await repository.requestDownload('a');

        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
      });
    });
  });
}

/// Lets the broadcast stream deliver any pending events.
Future<void> _settle() => Future<void>.delayed(Duration.zero);
