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

  /// The most recent app lifecycle state seen (`resumed`, `paused`, …), retained
  /// for diagnostics so a bug report can show what transition the app was in.
  /// Null until the first transition. A fixed enum-name label — never a secret.
  static String? lastLifecycleState;

  /// The playback status (`playing`, `buffering`, `paused`, …) captured the last
  /// time the app was backgrounded, retained for diagnostics so a "music stopped
  /// when I locked the phone" report can show what state playback was in at that
  /// boundary. Null until the app has been backgrounded at least once.
  static String? playbackStateAtBackground;

  /// The last safe playback/stream interruption *kind* seen (an enum name or a
  /// fixed label like `load`/`resolution`), retained for diagnostics. Null until
  /// one occurs. Never the raw error (which can carry a tokenized URL).
  static String? lastInterruptionKind;

  /// An app lifecycle transition (`resumed`, `paused`, `inactive`, …) — the
  /// boundary most freezes/ANRs cluster around (background/foreground).
  static void lifecycle(String state) {
    lastLifecycleState = state;
    SafeEventLog.instance.record('lifecycle', state);
    _log(describeLifecycle(state));
  }

  static String describeLifecycle(String state) => 'lifecycle: $state';

  /// The playback status at the moment the app was backgrounded (screen off /
  /// app hidden). Retained in [playbackStateAtBackground] and recorded as a
  /// breadcrumb so a screen-off "playback stopped" report is correlatable.
  /// [status] is a stable [PlaybackStatus] name — never a track, URL, or token.
  static void backgroundPlaybackState(String status) {
    playbackStateAtBackground = status;
    SafeEventLog.instance.record('bg-playback', status);
    _log(describeBackgroundPlaybackState(status));
  }

  static String describeBackgroundPlaybackState(String status) =>
      'background playback: $status';

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
    lastInterruptionKind = kind;
    SafeEventLog.instance.record('error', kind);
    _log(describePlaybackError(kind));
  }

  static String describePlaybackError(String kind) => 'playback error: $kind';
}
