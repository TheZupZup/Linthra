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

  /// The last audio-focus event seen for the on-device engine and how it was
  /// handled (`loss:paused`, `regain:ignored`, `duck:ignored`, `noisy:paused`),
  /// retained for diagnostics. Null until one occurs.
  ///
  /// This is the breadcrumb that proves playback is *not* auto-resumed when
  /// audio focus comes back — the screen-wake / exit-Doze / exit-battery-saver /
  /// return-from-another-app path that used to surprise-start music. A regain is
  /// always recorded as `regain:ignored`, never a play. A fixed structural label
  /// — never a track, URL, or token.
  static String? lastAudioFocusEvent;

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

  /// An audio-focus event for the on-device engine and how it was handled.
  /// [event] is a fixed structural label — `loss:paused` (a real focus loss, so
  /// we paused), `regain:ignored` (focus came back; we did NOT resume),
  /// `duck:ignored`, or `noisy:paused` (headphones unplugged). Retained in
  /// [lastAudioFocusEvent] and recorded so a "music started by itself on screen
  /// wake / when leaving battery saver" report shows the focus regain was
  /// ignored rather than treated as a play. Never a track, URL, or token.
  static void audioFocus(String event) {
    lastAudioFocusEvent = event;
    SafeEventLog.instance.record('audio-focus', event);
    _log(describeAudioFocus(event));
  }

  static String describeAudioFocus(String event) => 'audio focus: $event';

  /// A media-session now-playing item re-broadcast that did NOT originate from
  /// playback — e.g. a cover finished warming so the card was refreshed to show
  /// the art. Recorded so a "cover art / metadata refresh restarted my music"
  /// report can show the rebroadcast happened off the playback path (it issues
  /// no transport command). [cause] is a fixed label such as `artwork` — never a
  /// URL, id, or title.
  static void mediaItemRebroadcast(String cause) {
    SafeEventLog.instance.record('rebroadcast', cause);
    _log(describeMediaItemRebroadcast(cause));
  }

  static String describeMediaItemRebroadcast(String cause) =>
      'media item rebroadcast: $cause';

  /// A play command that arrived through the platform media session — a user
  /// tapping the notification / lock-screen play, or Android Auto / Bluetooth /
  /// a headset sending PLAY. Recorded so every legitimate resume is accounted
  /// for and distinguishable from an unwanted self-resume (which no longer
  /// happens). [source] is a fixed label such as `media-session`.
  static void playCommand(String source) {
    SafeEventLog.instance.record('play', source);
    _log(describePlayCommand(source));
  }

  static String describePlayCommand(String source) => 'play command: $source';

  /// A pause command that arrived through the platform media session — a user
  /// tapping the notification / lock-screen pause, or Android Auto / Bluetooth /
  /// a headset sending PAUSE. (Android routes all of these through the one media
  /// session, so the specific transport isn't distinguishable here; the label is
  /// `media-session`.) Recorded so a screen-off "it paused by itself" report can
  /// tell a real session PAUSE apart from an audio-focus-loss pause
  /// (`audio focus: loss-*`), a becoming-noisy pause (`audio focus: noisy:*`), or
  /// an in-app user pause (which goes through the controller, not the session, so
  /// it carries no `pause command` breadcrumb).
  static void pauseCommand(String source) {
    SafeEventLog.instance.record('pause', source);
    _log(describePauseCommand(source));
  }

  static String describePauseCommand(String source) => 'pause command: $source';
}
