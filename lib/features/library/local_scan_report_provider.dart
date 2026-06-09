import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sources/local/local_scan_diagnostics.dart';
import '../../core/sources/local/local_scan_report.dart';

/// The latest local-folder scan outcome, exposed reactively so the Settings
/// "Local music" card can show what the last scan saw (counts, read failures,
/// error) and refresh the moment a new scan finishes.
///
/// It mirrors the process-wide [LocalScanDiagnostics] static (which the
/// secret-free diagnostics export reads independently of Riverpod): recording a
/// report here also records it there, so the two never drift. Seeded from
/// [LocalScanDiagnostics.last] so a report survives navigating away and back.
class LocalScanReportController extends Notifier<LocalScanReport?> {
  @override
  LocalScanReport? build() => LocalScanDiagnostics.last;

  /// Records [report] as the latest scan outcome — both reactively (this
  /// provider's state) and in the static diagnostics recorder/event log.
  void record(LocalScanReport report) {
    LocalScanDiagnostics.record(report);
    state = report;
  }

  /// Forgets the retained outcome (e.g. after the user clears the folder).
  void clear() {
    LocalScanDiagnostics.reset();
    state = null;
  }
}

final localScanReportProvider =
    NotifierProvider<LocalScanReportController, LocalScanReport?>(
  LocalScanReportController.new,
);
