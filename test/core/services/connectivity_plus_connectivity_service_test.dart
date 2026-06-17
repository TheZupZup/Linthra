import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/connectivity_plus_connectivity_service.dart';
import 'package:linthra/core/services/connectivity_service.dart';

/// A stand-in for the plugin's [Connectivity] that returns canned results, so
/// the mapping from `connectivity_plus`' transport list to [NetworkStatus] can
/// be exercised without a device or platform channel.
class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this.results,
      {this.changes = const <List<ConnectivityResult>>[],
      this.throwOnCheck = false});

  /// What [checkConnectivity] reports.
  List<ConnectivityResult> results;

  /// What [onConnectivityChanged] emits, in order.
  final List<List<ConnectivityResult>> changes;

  /// When true, [checkConnectivity] throws, to prove a failed read is handled.
  final bool throwOnCheck;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    if (throwOnCheck) throw Exception('platform read failed');
    return results;
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream<List<ConnectivityResult>>.fromIterable(changes);
}

void main() {
  Future<NetworkStatus> statusFor(List<ConnectivityResult> results) {
    return ConnectivityPlusConnectivityService(
      connectivity: _FakeConnectivity(results),
    ).currentStatus();
  }

  group('ConnectivityPlusConnectivityService.currentStatus', () {
    test('Wi-Fi is unmetered', () async {
      expect(await statusFor([ConnectivityResult.wifi]), NetworkStatus.wifi);
    });

    test('Ethernet is treated as unmetered Wi-Fi', () async {
      expect(
        await statusFor([ConnectivityResult.ethernet]),
        NetworkStatus.wifi,
      );
    });

    test('mobile/cellular is metered', () async {
      expect(
        await statusFor([ConnectivityResult.mobile]),
        NetworkStatus.mobile,
      );
    });

    test('no connection is offline', () async {
      expect(await statusFor([ConnectivityResult.none]), NetworkStatus.offline);
    });

    test('an empty result list is offline (never assumed unmetered)', () async {
      expect(await statusFor(<ConnectivityResult>[]), NetworkStatus.offline);
    });

    test('VPN alone is unknown (conservative, not assumed Wi-Fi)', () async {
      expect(await statusFor([ConnectivityResult.vpn]), NetworkStatus.unknown);
    });

    test('Bluetooth alone is unknown (conservative)', () async {
      expect(
        await statusFor([ConnectivityResult.bluetooth]),
        NetworkStatus.unknown,
      );
    });

    test('satellite alone is unknown (conservative)', () async {
      expect(
        await statusFor([ConnectivityResult.satellite]),
        NetworkStatus.unknown,
      );
    });

    test('Wi-Fi alongside VPN still reads as unmetered Wi-Fi', () async {
      expect(
        await statusFor([ConnectivityResult.wifi, ConnectivityResult.vpn]),
        NetworkStatus.wifi,
      );
    });

    test('mobile alongside VPN stays metered', () async {
      expect(
        await statusFor([ConnectivityResult.mobile, ConnectivityResult.vpn]),
        NetworkStatus.mobile,
      );
    });

    test('mobile alongside satellite stays metered', () async {
      expect(
        await statusFor(
          [ConnectivityResult.mobile, ConnectivityResult.satellite],
        ),
        NetworkStatus.mobile,
      );
    });

    test('Wi-Fi present with mobile prefers unmetered Wi-Fi', () async {
      expect(
        await statusFor([ConnectivityResult.wifi, ConnectivityResult.mobile]),
        NetworkStatus.wifi,
      );
    });

    test('a failed platform read falls back to unknown, never Wi-Fi', () async {
      final service = ConnectivityPlusConnectivityService(
        connectivity: _FakeConnectivity(
          const <ConnectivityResult>[],
          throwOnCheck: true,
        ),
      );
      expect(await service.currentStatus(), NetworkStatus.unknown);
    });
  });

  group('ConnectivityPlusConnectivityService.statusStream', () {
    test('maps each emitted transport list to a NetworkStatus', () async {
      final service = ConnectivityPlusConnectivityService(
        connectivity: _FakeConnectivity(
          const <ConnectivityResult>[],
          changes: const <List<ConnectivityResult>>[
            [ConnectivityResult.wifi],
            [ConnectivityResult.mobile],
            [ConnectivityResult.none],
          ],
        ),
      );
      expect(
        await service.statusStream.toList(),
        <NetworkStatus>[
          NetworkStatus.wifi,
          NetworkStatus.mobile,
          NetworkStatus.offline,
        ],
      );
    });
  });
}
