import 'dart:async';

import 'package:flutter/services.dart';
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

/// Android's network channels as MainActivity registers them
/// (NetworkStatusChannel.kt): a one-shot status question, and a change stream
/// that starts reporting once Dart listens, with the current status first and
/// then every change, repeats dropped.
class _AndroidNetworkChannels {
  _AndroidNetworkChannels(this._messenger, {required this.status});

  static const MethodChannel _method =
      MethodChannel('io.github.thezupzup.linthra/network_status');
  static const EventChannel _events =
      EventChannel('io.github.thezupzup.linthra/network_status_events');

  final TestDefaultBinaryMessenger _messenger;
  String status;
  MockStreamHandlerEventSink? _sink;
  String? _lastSent;

  /// MainActivity.configureFlutterEngine: the channels exist from now on.
  void register() {
    _messenger.setMockMethodCallHandler(
      _method,
      (MethodCall call) async =>
          call.method == 'getNetworkStatus' ? status : null,
    );
    _messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (Object? _, MockStreamHandlerEventSink sink) {
          _sink = sink;
          _lastSent = null;
          _report();
        },
        onCancel: (Object? _) => _sink = null,
      ),
    );
  }

  void unregister() {
    _messenger.setMockMethodCallHandler(_method, null);
    _messenger.setMockStreamHandler(_events, null);
  }

  /// The phone moved to another network.
  void moveTo(String next) {
    status = next;
    _report();
  }

  void _report() {
    final MockStreamHandlerEventSink? sink = _sink;
    if (sink == null || status == _lastSent) return;
    _lastSent = status;
    sink.success(status);
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
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

  for (final HostPlatform host in <HostPlatform>[
    HostPlatform.android,
    HostPlatform.linux,
  ]) {
    test('on ${host.name} a download held for Wi-Fi starts when Wi-Fi arrives',
        () async {
      final DownloadRepository repository =
          container(host).read(downloadRepositoryProvider);

      expect(
        await repository.requestDownload(_track),
        DownloadRequestOutcome.waitingForWifi,
      );
      connectivity.moveTo(NetworkStatus.wifi);
      await _settle();

      expect(downloader.fetches, 1);
      expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
    });
  }

  test(
      'on android a download held for Wi-Fi starts when Wi-Fi arrives, '
      'even when the engine started before the app was opened', () async {
    // Android Auto, the system's media controls or a headset button start
    // Linthra's engine from its media service, before any activity: the
    // download queue starts following network changes right away, but
    // MainActivity registers the network channels only once the listener
    // opens the app.
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
        remoteTrackDownloaderProvider.overrideWithValue(downloader),
      ],
    );
    addTearDown(c.dispose);
    final DownloadRepository repository = c.read(downloadRepositoryProvider);
    await _settle();

    // The listener opens Linthra, on mobile data.
    final _AndroidNetworkChannels android = _AndroidNetworkChannels(
      binding.defaultBinaryMessenger,
      status: 'metered',
    )..register();
    addTearDown(android.unregister);
    expect(
      await repository.requestDownload(_track),
      DownloadRequestOutcome.waitingForWifi,
    );

    // Home, on Wi-Fi.
    android.moveTo('unmetered');
    await _settle();

    expect(downloader.fetches, 1);
    expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
  });

  test('where nothing reports network changes, none are listened to', () async {
    final DownloadRepository repository =
        container(HostPlatform.windows).read(downloadRepositoryProvider);

    await repository.requestDownload(_track);

    expect(connectivity.listeners, 0);
    // A policy change still lets it through.
    connectivity.status = NetworkStatus.wifi;
    await repository.retryHeldDownloads();
    expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
  });
}
