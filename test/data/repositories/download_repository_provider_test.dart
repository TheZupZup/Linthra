import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';

/// A connectivity stand-in the test moves between networks, reporting each
/// move on [statusStream] the way Android's network channel does.
class _MovingConnectivity implements ConnectivityService {
  NetworkStatus status = NetworkStatus.mobile;
  final StreamController<NetworkStatus> _changes =
      StreamController<NetworkStatus>.broadcast();

  int listeners = 0;

  void moveTo(NetworkStatus next) {
    status = next;
    _changes.add(next);
  }

  @override
  Stream<NetworkStatus> get statusStream {
    listeners++;
    return _changes.stream;
  }

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

class _Downloader implements RemoteTrackDownloader {
  int fetches = 0;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetches++;
    return const RemoteTrackData(bytes: <int>[1, 2, 3], fileExtension: 'mp3');
  }
}

const Track _track = Track(id: 'j1', title: 'j1', uri: 'jellyfin:j1');

Future<void> _settle() async {
  for (int i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _MovingConnectivity connectivity;
  late _Downloader downloader;

  ProviderContainer container(HostPlatform host) {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(host),
        connectivityServiceProvider.overrideWithValue(connectivity),
        remoteTrackDownloaderProvider.overrideWithValue(downloader),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    connectivity = _MovingConnectivity();
    downloader = _Downloader();
  });

  test('on Android a download held for Wi-Fi starts when Wi-Fi arrives',
      () async {
    final DownloadRepository repository =
        container(HostPlatform.android).read(downloadRepositoryProvider);

    expect(
      await repository.requestDownload(_track),
      DownloadRequestOutcome.waitingForWifi,
    );
    connectivity.moveTo(NetworkStatus.wifi);
    await _settle();

    expect(downloader.fetches, 1);
    expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
  });

  test('on Linux the channel-less status stream is never listened to',
      () async {
    final DownloadRepository repository =
        container(HostPlatform.linux).read(downloadRepositoryProvider);

    await repository.requestDownload(_track);

    expect(connectivity.listeners, 0);
    // A policy change still lets it through.
    connectivity.status = NetworkStatus.wifi;
    await repository.retryHeldDownloads();
    expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
  });
}
