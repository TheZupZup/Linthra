import '../repositories/download_repository.dart';
import '../services/connectivity_service.dart';
import '../services/download_gate.dart';
import '../services/download_state.dart';
import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// The download rules in the Rust core (native/linthra_core/src/ffi/downloads.rs).
///
/// Use [downloadGate], [settleCanceled] and [heldAction], which call this and
/// fall back to their Dart rules without the Rust core. Each method returns
/// null when there is no Rust core, or when it did not know a code.
abstract final class NativeDownloads {
  static DownloadGate? gate(NetworkStatus network, bool allowMobileData) {
    if (!LinthraCore.isAvailable) return null;
    return _decode(
      DownloadGate.values,
      linthraDownloadGate(network.index, allowMobileData),
    );
  }

  /// A record: `null` itself means no Rust answer, while a `settled` of null
  /// means leave the row.
  static ({DownloadStatus? settled})? settleCanceled(
    DownloadStatus? row,
    CommittedCopy committed,
  ) {
    if (!LinthraCore.isAvailable) return null;
    final int code = linthraDownloadSettleCanceled(_row(row), committed.index);
    if (code == LinthraDownloadCode.none) return (settled: null);
    final DownloadStatus? status = _decode(DownloadStatus.values, code);
    return status == null ? null : (settled: status);
  }

  static HeldAction? heldAction(
    bool sameAccount,
    bool inFlight,
    DownloadStatus? row,
  ) {
    if (!LinthraCore.isAvailable) return null;
    return _decode(
      HeldAction.values,
      linthraDownloadHeldAction(sameAccount, inFlight, _row(row)),
    );
  }

  static int _row(DownloadStatus? row) =>
      row?.index ?? LinthraDownloadCode.none;

  static T? _decode<T>(List<T> values, int code) =>
      code < values.length ? values[code] : null;
}
