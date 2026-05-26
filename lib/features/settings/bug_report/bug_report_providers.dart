import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/diagnostics/app_diagnostics.dart';
import '../../../core/diagnostics/safe_event_log.dart';
import '../../../core/services/external_link_launcher.dart';
import '../diagnostics/diagnostics_collector.dart';

/// The secret-free inputs the bug-report screen renders from: the diagnostics
/// snapshot and the recent safe app events.
///
/// Collected once when the screen opens, then composed locally as the user
/// edits text and flips toggles — so the live preview never re-runs async work
/// on a keystroke.
class BugReportDiagnostics {
  const BugReportDiagnostics({
    required this.data,
    required this.recentEventLines,
  });

  /// The display-safe app snapshot (host-only addresses, counts, flags).
  final AppDiagnosticsData data;

  /// Recent secret-free breadcrumbs, oldest first, each `category: detail`.
  final List<String> recentEventLines;

  bool get hasRecentEvents => recentEventLines.isNotEmpty;
}

/// Collects the diagnostics snapshot and recent safe events for the bug report.
///
/// Overridden in tests with a fixed bundle so the screen can be exercised
/// without the playback/cast plugins behind the collector.
final bugReportDiagnosticsProvider =
    FutureProvider<BugReportDiagnostics>((ref) async {
  final AppDiagnosticsData data = await DiagnosticsCollector(ref).collect();
  return BugReportDiagnostics(
    data: data,
    recentEventLines: SafeEventLog.instance.lines,
  );
});

/// The browser seam the "Open GitHub issue" action launches through. Production
/// wires the `url_launcher`-backed launcher; tests override it with a fake so
/// no real browser is opened.
final externalLinkLauncherProvider = Provider<ExternalLinkLauncher>(
  (ref) => const UrlLauncherExternalLinkLauncher(),
);
