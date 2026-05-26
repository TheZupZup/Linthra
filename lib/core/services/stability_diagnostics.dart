import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../diagnostics/safe_event_log.dart';

/// Secret-free breadcrumb logs for diagnosing the field freezes/ANRs this
/// stabilization pass targets, and the playback-output handoffs that surround
/// them. Filter device logs with `adb logcat | grep linthra.stability`.
///
/// Each breadcrumb is also recorded into [SafeEventLog.instance] — a bounded,
/// in-memory ring buffer — so the "Report a bug" flow can include the last few
/// app events even in a release build, where the `developer.log` output below
/// is silent. The recorder runs in every build (it is just memory, no I/O) but
/// is surfaced only when the user explicitly opts in while building a report.
///
/// Secret-free *by construction*: every method takes only a fixed, structural
/// label — an output name, a lifecycle state, a pre-cache outcome, an error
/// *kind* (an enum name) — and there is no parameter for a token, password,
/// authenticated URL, track title, or local path. The `describe*` helpers are
/// pure and public so a test can assert the emitted line carries no secret.
abstract final class StabilityDiagnostics {
  /// The developer-log channel these breadcrumbs go to.
  static const String name = 'linthra.stability';

  static void _log(String message) {
    if (!kDebugMode) return;
    developer.log(message, name: name);
  }

  /// An app lifecycle transition (`resumed`, `paused`, `inactive`, …) — the
  /// boundary most freezes/ANRs cluster around (background/foreground).
  static void lifecycle(String state) {
    SafeEventLog.instance.record('lifecycle', state);
    _log(describeLifecycle(state));
  }

  static String describeLifecycle(String state) => 'lifecycle: $state';

  /// The active playback output changed (`local` / `cast`), so a handoff can be
  /// correlated with a freeze without logging anything about the track.
  static void output(String output) {
    SafeEventLog.instance.record('output', output);
    _log(describeOutput(output));
  }

  static String describeOutput(String output) => 'output -> $output';

  /// A smart pre-cache decision, by safe outcome: `start:<count>`,
  /// `skip:<reason>` (e.g. `skip:disabled`, `skip:repeat-one`). No track id,
  /// title, or URL is ever included.
  static void precache(String outcome) {
    SafeEventLog.instance.record('precache', outcome);
    _log(describePrecache(outcome));
  }

  static String describePrecache(String outcome) => 'precache: $outcome';

  /// A playback / stream-resolution failure, by its safe [kind] (a
  /// [StreamInterruptionKind] name or a fixed label like `resolution`/`load`) —
  /// never the raw error, which can carry a tokenized URL.
  static void playbackError(String kind) {
    SafeEventLog.instance.record('error', kind);
    _log(describePlaybackError(kind));
  }

  static String describePlaybackError(String kind) => 'playback error: $kind';
}
