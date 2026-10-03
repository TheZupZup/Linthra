import 'dart:async';

import 'package:flutter/services.dart';

import 'connectivity_service.dart';

/// Reads the platform's current network classification.
typedef PlatformNetworkStatusReader = Future<Object?> Function();

/// Android-backed [ConnectivityService] using the platform's active-network
/// metering state rather than assuming every connection is Wi-Fi.
///
/// Android reports whether the app's default network is metered or unmetered.
/// That is the signal download policy actually needs: a metered Wi-Fi hotspot is
/// treated cautiously, while an unmetered cellular plan can be treated like any
/// other unmetered connection. VPNs are classified from the default network
/// Android exposes to this app.
///
/// Platform failures are deliberately mapped to [NetworkStatus.unknown]. The
/// download repository treats that conservatively, so a missing channel or an
/// unusual device can never silently become "free Wi-Fi".
class AndroidConnectivityService implements ConnectivityService {
  AndroidConnectivityService({
    PlatformNetworkStatusReader? statusReader,
    Stream<Object?>? statusEvents,
  })  : _statusReader = statusReader ?? _readPlatformStatus,
        _statusEvents = statusEvents ??
            const EventChannel(_eventChannelName).receiveBroadcastStream();

  static const String _methodChannelName =
      'io.github.thezupzup.linthra/network_status';
  static const String _eventChannelName =
      'io.github.thezupzup.linthra/network_status_events';

  static const MethodChannel _methodChannel = MethodChannel(_methodChannelName);

  final PlatformNetworkStatusReader _statusReader;
  final Stream<Object?> _statusEvents;

  /// Shared by every listener: smart pre-cache and the download queue both
  /// follow it, and a stream built from an `async*` generator can only be
  /// listened to once. A listener that joins later hears the changes from
  /// then on.
  late final Stream<NetworkStatus> _changes =
      _platformChanges().distinct().asBroadcastStream();

  /// Completes once the platform has answered a status question, which is
  /// when its change stream can be listened to. MainActivity registers both
  /// channels when it attaches to the engine, and Android Auto, the system's
  /// media controls or a headset button start the engine from the media
  /// service, before any activity. A listen sent before then is refused and
  /// never sent again, which would leave the stream silent for good.
  final Completer<void> _answered = Completer<void>();

  @override
  Stream<NetworkStatus> get statusStream => _changes;

  @override
  Future<NetworkStatus> currentStatus() async {
    try {
      final Object? value = await _statusReader();
      if (!_answered.isCompleted) _answered.complete();
      return decodePlatformStatus(value);
    } catch (_) {
      return NetworkStatus.unknown;
    }
  }

  Stream<NetworkStatus> _platformChanges() async* {
    // Asked now, so a running activity is listened to at once; otherwise the
    // first question it answers (a download, a pre-cache) starts listening.
    await currentStatus();
    await _answered.future;
    try {
      await for (final Object? value in _statusEvents) {
        yield decodePlatformStatus(value);
      }
    } catch (_) {
      // A platform-channel failure must fail closed for large downloads.
      yield NetworkStatus.unknown;
    }
  }

  static Future<Object?> _readPlatformStatus() =>
      _methodChannel.invokeMethod<Object?>('getNetworkStatus');

  /// Maps the small, credential-free platform vocabulary onto Linthra's
  /// provider-independent policy enum.
  static NetworkStatus decodePlatformStatus(Object? value) {
    switch (value) {
      case 'unmetered':
        return NetworkStatus.wifi;
      case 'metered':
        return NetworkStatus.mobile;
      case 'offline':
        return NetworkStatus.offline;
      case 'unknown':
      default:
        return NetworkStatus.unknown;
    }
  }
}
