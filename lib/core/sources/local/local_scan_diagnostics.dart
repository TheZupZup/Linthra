import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../diagnostics/safe_event_log.dart';
import 'local_scan_report.dart';

/// Holds the last local-folder scan outcome so the diagnostics report and the
/// "Report a bug" flow can show *why* a scan found no music — selected-folder
/// presence, files visited, audio candidates, skipped/unsupported, read
/// failures, and the last error — without anyone re-running a scan.
///
/// Secret-free by construction: it stores only a [LocalScanReport], which holds
/// booleans, counts, and a fixed error enum — no folder path, file name, or raw
/// error string. The breadcrumb mirrored into [SafeEventLog] is likewise just
/// `category: detail` with structural counts, so nothing sensitive is recorded.
///
/// A process-wide static, matching the plugin-free style of the other
/// diagnostics utilities (`StabilityDiagnostics`) that the report already reads.
abstract final class LocalScanDiagnostics {
  /// The developer-log channel these breadcrumbs go to (debug builds only).
  static const String name = 'linthra.scan';

  /// The most recent scan outcome, or null until the first scan runs.
  static LocalScanReport? last;

  /// Records [report] as the latest scan outcome and drops a secret-free
  /// breadcrumb into the shared event log.
  static void record(LocalScanReport report) {
    last = report;
    SafeEventLog.instance.record('scan', describe(report));
    if (kDebugMode) {
      developer.log(describe(report), name: name);
    }
  }

  /// Clears the retained outcome. For tests, so one case can't leak into the
  /// next.
  static void reset() => last = null;

  /// A one-line, secret-free summary of [report] — counts and a fixed error
  /// label only. Pure and public so a test can assert it carries no secret (it
  /// cannot: there is no parameter for a path, name, or raw error).
  static String describe(LocalScanReport report) {
    return <String>[
      'folder=${report.folderSelected ? 'selected' : 'none'}',
      if (report.folderSelected) 'kind=${report.isContentUri ? 'saf' : 'path'}',
      'visited=${report.filesVisited}',
      'folders=${report.foldersVisited}',
      'audio=${report.audioCandidates}',
      'imported=${report.importedTracks}',
      'skipped=${report.skippedUnsupported}',
      'readFailures=${report.readFailures}',
      'recursive=${report.recursive ? 'yes' : 'no'}',
      if (report.error != null) 'error=${report.error!.name}',
    ].join(' ');
  }
}
