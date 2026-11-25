// The stream recovery rules give the same answers in Dart and in the Rust
// core (native/linthra_core/src/stream_recovery.rs): every status the rules
// read, a grid of positions around each threshold, and the reconnect budget
// through the same runs of position reports.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/services/stream_recovery_rules.dart';

const Duration _s = Duration(seconds: 1);

void main() {
  final Object skip =
      LinthraCore.isAvailable ? false : 'Rust core not built in this build';

  test('the end or loss of a source', skip: skip, () {
    final List<Duration> durations = <Duration>[
      Duration.zero,
      const Duration(milliseconds: 4048),
      _s * 40,
      _s * 3600,
    ];
    int compared = 0;
    for (final Duration duration in durations) {
      // Around every threshold: a quarter, two seconds, a tenth, ten seconds.
      final Set<Duration> positions = <Duration>{
        Duration.zero,
        -_s,
        duration,
        duration + _s,
        for (final Duration back in <Duration>[
          duration ~/ 4,
          _s * 2,
          duration ~/ 10,
          _s * 10,
        ])
          for (final int nudge in <int>[-1, 0, 1])
            duration - back + Duration(microseconds: nudge),
      };
      for (final SourceGone gone in SourceGone.values) {
        for (final bool linux in <bool>[false, true]) {
          for (final bool stream in <bool>[false, true]) {
            for (final PlaybackStatus status in PlaybackStatus.values) {
              for (final Duration position in positions) {
                SourceEnd answer({required bool useNative}) => sourceEnd(
                      gone,
                      engineReportsFailureAsIdle: linux,
                      stream: stream,
                      status: status,
                      position: position,
                      duration: duration,
                      useNative: useNative,
                    );
                expect(answer(useNative: true), answer(useNative: false),
                    reason: '$gone linux=$linux stream=$stream $status '
                        '$position of $duration');
                compared++;
              }
            }
          }
        }
      }
    }
    expect(compared, 3584);
  });

  test('the buffering watchdog', skip: skip, () {
    for (final PlaybackStatus a in PlaybackStatus.values) {
      for (final PlaybackStatus b in PlaybackStatus.values) {
        for (final bool flag in <bool>[false, true]) {
          expect(watchdogArms(a, b, hasPlayed: flag),
              watchdogArms(a, b, hasPlayed: flag, useNative: false),
              reason: 'arms $a $b $flag');
        }
      }
      for (final bool recovery in <bool>[false, true]) {
        for (final bool track in <bool>[false, true]) {
          expect(
              watchdogFails(a, recoveryUnderway: recovery, hasTrack: track),
              watchdogFails(a,
                  recoveryUnderway: recovery,
                  hasTrack: track,
                  useNative: false),
              reason: 'fails $a $recovery $track');
        }
      }
    }
  });

  test('the reconnect budget', skip: skip, () {
    // Runs of reports: steady playback, a seek forward, a step back, time
    // that doesn't count, and a refill partway.
    final List<(Duration, bool)> reports = <(Duration, bool)>[
      for (int i = 0; i < 40; i++) (_s * i ~/ 2, true),
      (_s * 30, true),
      (_s * 29, true),
      (_s * 29 + _s ~/ 4, false),
      for (int i = 0; i < 80; i++) (_s * 30 + _s * i ~/ 4, true),
    ];
    final ReconnectBudget rust = ReconnectBudget();
    final ReconnectBudget dart = ReconnectBudget(useNative: false);
    for (final ReconnectBudget budget in <ReconnectBudget>[rust, dart]) {
      expect(budget.claim(retryable: false, max: 1), isFalse);
      expect(budget.claim(retryable: true, max: 1), isTrue);
      expect(budget.claim(retryable: true, max: 1), isFalse);
    }
    for (final (Duration position, bool counting) in reports) {
      for (final ReconnectBudget budget in <ReconnectBudget>[rust, dart]) {
        budget.noteProgress(position, counting: counting, refillAfter: _s * 15);
      }
      expect('${rust.spent} ${rust.played} ${rust.last}',
          '${dart.spent} ${dart.played} ${dart.last}',
          reason: 'at $position counting=$counting');
    }
    // The run gave the reconnect back.
    expect(rust.spent, 0);
  });
}
