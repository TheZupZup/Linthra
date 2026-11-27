// The stream recovery rules, which run in the Rust core
// (native/linthra_core/src/stream_recovery.rs): whether a source that went
// away ended or was lost, the buffering watchdog, and the quick reconnect
// budget, through the same calls the player makes.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/services/stream_recovery_rules.dart';

const Duration _s = Duration(seconds: 1);

SourceEnd _end(
  SourceGone gone, {
  bool linux = true,
  bool stream = true,
  PlaybackStatus status = PlaybackStatus.playing,
  required Duration position,
  Duration duration = const Duration(minutes: 4),
}) =>
    sourceEnd(
      gone,
      engineReportsFailureAsIdle: linux,
      stream: stream,
      status: status,
      position: position,
      duration: duration,
    );

void main() {
  group('the end or loss of a source', () {
    test('an idle heard to within two seconds of the end is its end', () {
      expect(_end(SourceGone.idle, position: _s * 239), SourceEnd.ended);
      expect(_end(SourceGone.idle, position: _s * 230), SourceEnd.lost);
    });

    test('a short track counts a quarter of it as the end', () {
      expect(
        _end(SourceGone.idle, position: _s * 3, duration: _s * 4),
        SourceEnd.ended,
      );
      expect(
        _end(SourceGone.idle, position: _s * 2, duration: _s * 4),
        SourceEnd.lost,
      );
    });

    test('an idle not heard (paused, stopped) is a loss', () {
      expect(
        _end(
          SourceGone.idle,
          status: PlaybackStatus.paused,
          position: _s * 239,
        ),
        SourceEnd.lost,
      );
    });

    test("a Linux stream's completion well short of its end is a loss (#905)",
        () {
      expect(_end(SourceGone.completed, position: _s * 100), SourceEnd.lost);
      // Within ten seconds or a tenth of the track it ended, an estimated
      // VBR length included.
      expect(_end(SourceGone.completed, position: _s * 230), SourceEnd.ended);
      expect(
        _end(SourceGone.completed, stream: false, position: _s * 100),
        SourceEnd.ended,
      );
      expect(
        _end(SourceGone.completed, linux: false, position: _s * 100),
        SourceEnd.ended,
      );
    });
  });

  group('the buffering watchdog', () {
    test('arms on a stall while playing, or after the track has played', () {
      expect(
        watchdogArms(
          PlaybackStatus.buffering,
          PlaybackStatus.playing,
          hasPlayed: false,
        ),
        isTrue,
      );
      expect(
        watchdogArms(
          PlaybackStatus.buffering,
          PlaybackStatus.paused,
          hasPlayed: true,
        ),
        isTrue,
      );
      // A first load is not a stall.
      expect(
        watchdogArms(
          PlaybackStatus.buffering,
          PlaybackStatus.loading,
          hasPlayed: false,
        ),
        isFalse,
      );
      expect(
        watchdogArms(
          PlaybackStatus.playing,
          PlaybackStatus.playing,
          hasPlayed: true,
        ),
        isFalse,
      );
    });

    test('fails only while stalled, with a track and no recovery under way',
        () {
      expect(
        watchdogFails(
          PlaybackStatus.buffering,
          recoveryUnderway: false,
          hasTrack: true,
        ),
        isTrue,
      );
      expect(
        watchdogFails(
          PlaybackStatus.reconnecting,
          recoveryUnderway: false,
          hasTrack: true,
        ),
        isTrue,
      );
      expect(
        watchdogFails(
          PlaybackStatus.buffering,
          recoveryUnderway: true,
          hasTrack: true,
        ),
        isFalse,
      );
      expect(
        watchdogFails(
          PlaybackStatus.playing,
          recoveryUnderway: false,
          hasTrack: true,
        ),
        isFalse,
      );
    });
  });

  test('the reconnect budget is spent once and earned back by playback', () {
    final ReconnectBudget budget = ReconnectBudget();
    expect(budget.claim(retryable: false, max: 1), isFalse);
    expect(budget.claim(retryable: true, max: 1), isTrue);
    expect(budget.claim(retryable: true, max: 1), isFalse);

    // A seek forward, a step back and time that doesn't count earn nothing.
    budget.noteProgress(_s * 10, counting: true, refillAfter: _s * 15);
    budget.noteProgress(_s * 40, counting: true, refillAfter: _s * 15);
    budget.noteProgress(_s * 39, counting: true, refillAfter: _s * 15);
    budget.noteProgress(_s * 50, counting: false, refillAfter: _s * 15);
    expect(budget.spent, 1);

    // Fifteen seconds of steady playback give it back.
    for (int i = 0; i <= 40; i++) {
      budget.noteProgress(
        _s * 60 + _s * i ~/ 2,
        counting: true,
        refillAfter: _s * 15,
      );
    }
    expect(budget.spent, 0);
    expect(budget.claim(retryable: true, max: 1), isTrue);
  });
}
