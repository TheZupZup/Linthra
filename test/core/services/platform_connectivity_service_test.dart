import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/platform_connectivity_service.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';

void main() {
  group('PlatformConnectivityService', () {
    test('maps platform statuses without pretending unknown is Wi-Fi', () {
      expect(
        PlatformConnectivityService.statusFromPlatform('wifi'),
        NetworkStatus.wifi,
      );
      expect(
        PlatformConnectivityService.statusFromPlatform('mobile'),
        NetworkStatus.mobile,
      );
      expect(
        PlatformConnectivityService.statusFromPlatform('offline'),
        NetworkStatus.offline,
      );
      expect(
        PlatformConnectivityService.statusFromPlatform('bluetooth'),
        NetworkStatus.unknown,
      );
      expect(
        PlatformConnectivityService.statusFromPlatform(null),
        NetworkStatus.unknown,
      );
    });

    test('production provider uses platform connectivity service', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(connectivityServiceProvider),
        isA<PlatformConnectivityService>(),
      );
    });
  });
}
