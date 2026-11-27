import '../repositories/download_repository.dart';
import '../services/connectivity_service.dart';
import '../services/download_gate.dart';
import '../services/download_state.dart';
import 'linthra_core_ffi.dart';

/// The download rules in the Rust core (native/linthra_core/src/ffi/downloads.rs).
///
/// Use [downloadGate], [settleCanceled] and [heldAction], which call this.
/// Every code sent comes from a Dart enum, so an answer Rust doesn't know
/// means the two sides of the ABI disagree, and throws.
abstract final class NativeDownloads {
  static DownloadGate gate(NetworkStatus network, bool allowMobileData) =>
      _decode(
        DownloadGate.values,
        linthraDownloadGate(network.index, allowMobileData),
      );

  /// The status to leave on the row, or null to leave it as it is.
  static DownloadStatus? settleCanceled(
    DownloadStatus? row,
    CommittedCopy committed,
  ) {
    final int code = linthraDownloadSettleCanceled(_row(row), committed.index);
    if (code == LinthraDownloadCode.none) return null;
    return _decode(DownloadStatus.values, code);
  }

  static HeldAction heldAction(
    bool sameAccount,
    bool inFlight,
    DownloadStatus? row,
  ) =>
      _decode(
        HeldAction.values,
        linthraDownloadHeldAction(sameAccount, inFlight, _row(row)),
      );

  static int _row(DownloadStatus? row) =>
      row?.index ?? LinthraDownloadCode.none;

  static T _decode<T>(List<T> values, int code) {
    if (code >= values.length) {
      throw StateError('the Rust download rules answered an unknown $code');
    }
    return values[code];
  }
}
