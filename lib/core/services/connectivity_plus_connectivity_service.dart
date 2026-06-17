import 'package:connectivity_plus/connectivity_plus.dart';

import 'connectivity_service.dart';

/// The real [ConnectivityService], backed by the `connectivity_plus` plugin, so
/// the offline-download and smart-pre-cache mobile-data gate sees the *actual*
/// link type instead of the optimistic "always Wi-Fi" placeholder
/// ([OptimisticConnectivityService]). This is the implementation the existing
/// gate was designed for; wiring it in is what makes "Allow mobile data"
/// actually hold pre-cache and downloads back off a metered connection.
///
/// The mapping is deliberately conservative — the safe default is "don't spend
/// mobile data without permission":
///  - Wi-Fi or Ethernet (unmetered) -> [NetworkStatus.wifi].
///  - Mobile/cellular -> [NetworkStatus.mobile] (allowed only when the user
///    turned on "Allow mobile data").
///  - No connection -> [NetworkStatus.offline].
///  - Anything else or indeterminate (VPN, Bluetooth, satellite, "other", an
///    empty list, or a failed read) -> [NetworkStatus.unknown], which the policy
///    already treats like mobile data — so an undetermined link is never assumed
///    unmetered and never pre-caches silently over a metered connection.
///
/// The platform can report several transports at once (e.g. `[wifi, vpn]`); the
/// mapping prefers the safe interpretation, only reporting [NetworkStatus.wifi]
/// when an unmetered transport is actually present.
///
/// It depends only on `connectivity_plus`, which reads Android's standard
/// `ConnectivityManager` (no Google Play Services), so it stays F-Droid /
/// open-source compatible. The rest of the app keeps depending on the
/// [ConnectivityService] interface, never on the plugin directly.
class ConnectivityPlusConnectivityService implements ConnectivityService {
  ConnectivityPlusConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Stream<NetworkStatus> get statusStream =>
      _connectivity.onConnectivityChanged.map(_mapResults);

  @override
  Future<NetworkStatus> currentStatus() async {
    try {
      return _mapResults(await _connectivity.checkConnectivity());
    } catch (_) {
      // A failed read must never be mistaken for unmetered Wi-Fi; fall back to
      // the conservative "unknown" so the user's mobile-data choice still wins.
      return NetworkStatus.unknown;
    }
  }

  /// Collapses the platform's (possibly multi-transport) result list into a
  /// single [NetworkStatus], preferring the safe reading when transports mix.
  static NetworkStatus _mapResults(List<ConnectivityResult> results) {
    if (results.isEmpty ||
        results.every((ConnectivityResult r) => r == ConnectivityResult.none)) {
      return NetworkStatus.offline;
    }
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return NetworkStatus.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkStatus.mobile;
    }
    // VPN / Bluetooth / satellite / "other" / unrecognised: don't assume the
    // link is unmetered — treat it as unknown so the mobile-data gate applies.
    return NetworkStatus.unknown;
  }
}
