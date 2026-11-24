import 'connectivity_service.dart';

/// Whether the network lets a download run now, and why not when it doesn't.
enum DownloadGate {
  allowed,

  /// Held until Wi-Fi, or until the user allows mobile data.
  needsWifi,

  /// Held until a connection returns.
  offline,
}

/// The network rule for downloads. The same rule as
/// `native/linthra_core/src/download_gate.rs`, held to it by the cases in
/// `test/fixtures/download_gate_cases.txt`, which both replay.
///
///  - Unmetered ([NetworkStatus.wifi]): always allowed.
///  - Metered, or metering unknown: allowed only when the user turned on
///    "Allow mobile data". An unknown link is never assumed to be free.
///  - Offline: never; the download waits for a connection.
DownloadGate downloadGate(
  NetworkStatus network, {
  required bool allowMobileData,
}) {
  switch (network) {
    case NetworkStatus.wifi:
      return DownloadGate.allowed;
    case NetworkStatus.mobile:
    case NetworkStatus.unknown:
      return allowMobileData ? DownloadGate.allowed : DownloadGate.needsWifi;
    case NetworkStatus.offline:
      return DownloadGate.offline;
  }
}
