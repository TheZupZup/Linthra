import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/android_connectivity_service.dart';
import 'package:linthra/core/services/portal_connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';

// A Linux desktop has no Android network channel, so it never knew whether
// its connection was metered, and the download policy holds an unknown link
// like mobile data. These run the real download graph on a Linux host, with
// the desktop's network monitor portal on a bus of the test's own.

class _NetworkMonitorPortal extends DBusObject {
  _NetworkMonitorPortal({required this.metered})
      : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  final bool metered;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.freedesktop.portal.NetworkMonitor' &&
        methodCall.name == 'GetMetered') {
      return DBusMethodSuccessResponse(<DBusValue>[DBusBoolean(metered)]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
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

void main() {
  late DBusServer server;
  late DBusAddress address;
  late DBusClient portalSide;
  late _Downloader downloader;

  setUp(() async {
    server = DBusServer();
    address =
        await server.listenAddress(DBusAddress.unix(dir: Directory.systemTemp));
    portalSide = DBusClient(address);
    downloader = _Downloader();
  });

  tearDown(() async {
    await portalSide.close();
    await server.close();
  });

  Future<ProviderContainer> linuxDesktop({required bool metered}) async {
    await portalSide.requestName('org.freedesktop.portal.Desktop');
    await portalSide.registerObject(_NetworkMonitorPortal(metered: metered));
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxSessionBusProvider.overrideWithValue(() => DBusClient(address)),
        remoteTrackDownloaderProvider.overrideWithValue(downloader),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('on an unmetered connection, a download starts with default settings',
      () async {
    final ProviderContainer container = await linuxDesktop(metered: false);
    final DownloadRepository repository =
        container.read(downloadRepositoryProvider);

    expect(
      await repository.requestDownload(_track),
      DownloadRequestOutcome.started,
    );
    expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
    expect(downloader.fetches, 1);
  });

  test('on a metered connection, "Wi-Fi only" still holds it', () async {
    final ProviderContainer container = await linuxDesktop(metered: true);
    final DownloadRepository repository =
        container.read(downloadRepositoryProvider);

    expect(
      await repository.requestDownload(_track),
      DownloadRequestOutcome.waitingForWifi,
    );
    expect(downloader.fetches, 0);
  });

  test('Linux reads the portal; Android keeps its own channel', () async {
    final ProviderContainer linux = await linuxDesktop(metered: false);
    expect(
      linux.read(connectivityServiceProvider),
      isA<PortalConnectivityService>(),
    );

    final ProviderContainer android = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
      ],
    );
    addTearDown(android.dispose);
    expect(
      android.read(connectivityServiceProvider),
      isA<AndroidConnectivityService>(),
    );
  });
}
