import 'dart:async';

import 'package:flutter/services.dart';

import 'connectivity_service.dart';

/// Production [ConnectivityService] backed by a tiny Android method/event
/// channel implemented in MainActivity.
///
/// Used only by the download/cache layer to decide whether background-heavy
/// downloads and smart pre-cache may run. Playback streaming does not depend on
/// this service, so a listener can still intentionally stream over LTE.
///
/// Fail-closed policy: platform errors or unrecognized transports map to
/// [NetworkStatus.unknown], which the download repository treats like mobile
/// data unless the user explicitly enabled mobile-data downloads/cache.
class PlatformConnectivityService implements ConnectivityService {
  const PlatformConnectivityService();

  static const MethodChannel _methods =
      MethodChannel('io.github.thezupzup.linthra/connectivity');
  static const EventChannel _events =
      EventChannel('io.github.thezupzup.linthra/connectivity_status');

  @override
  Stream<NetworkStatus> get statusStream => _statusStream().distinct();

  Stream<NetworkStatus> _statusStream() async* {
    try {
      await for (final Object? value in _events.receiveBroadcastStream()) {
        yield statusFromPlatform(value as String?);
      }
    } catch (_) {
      yield NetworkStatus.unknown;
    }
  }

  @override
  Future<NetworkStatus> currentStatus() async {
    try {
      final String? value = await _methods.invokeMethod<String>('currentStatus');
      return statusFromPlatform(value);
    } catch (_) {
      return NetworkStatus.unknown;
    }
  }

  /// Maps the stable platform-channel strings to the domain enum. Public for
  /// tests so production mapping can be verified without Android hardware.
  static NetworkStatus statusFromPlatform(String? value) {
    switch (value) {
      case 'wifi':
        return NetworkStatus.wifi;
      case 'mobile':
        return NetworkStatus.mobile;
      case 'offline':
        return NetworkStatus.offline;
      case 'unknown':
      default:
        return NetworkStatus.unknown;
    }
  }
}
