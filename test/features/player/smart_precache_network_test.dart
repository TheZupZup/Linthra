import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'fake_playback_controller.dart';

/// Counts who listens for network changes.
class _CountingConnectivity implements ConnectivityService {
  int listeners = 0;

  @override
  Stream<NetworkStatus> get statusStream {
    listeners++;
    return const Stream<NetworkStatus>.empty();
  }

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.mobile;
}

// Smart pre-cache resumes on a network change wherever the platform reports
// one, the same rule downloads held for Wi-Fi follow.
void main() {
  int listensFor(HostPlatform host) {
    final _CountingConnectivity connectivity = _CountingConnectivity();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(host),
        connectivityServiceProvider.overrideWithValue(connectivity),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
    );
    addTearDown(container.dispose);
    // The download queue it pre-caches through listens on its own.
    container.read(trackPrefetcherProvider);
    final int before = connectivity.listeners;

    container.read(smartPrecacheServiceProvider);
    return connectivity.listeners - before;
  }

  test('on Android smart pre-cache follows network changes', () {
    expect(listensFor(HostPlatform.android), 1);
  });

  test('on Linux it follows them too, from the network monitor portal', () {
    expect(listensFor(HostPlatform.linux), 1);
  });

  test('where nothing reports them, it does not listen', () {
    expect(listensFor(HostPlatform.windows), 0);
  });
}
