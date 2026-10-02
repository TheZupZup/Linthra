import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';
import 'package:linthra/core/services/provider_reachability.dart';

void main() {
  const PlaybackRecoveryPolicy policy = PlaybackRecoveryPolicy();

  PlaybackRecoveryDecision decide(
    PlaybackFailureKind kind, {
    String failed = 'jellyfin:a',
    String? next = 'jellyfin:b',
    PlaybackFailureStreak? streak,
  }) =>
      policy.decide(
        kind: kind,
        failedUri: failed,
        nextUri: next,
        streak: streak ?? PlaybackFailureStreak(),
      );

  group('PlaybackRecoveryPolicy', () {
    test('a source hiccup is retried once before anything is skipped', () {
      final PlaybackRecoveryDecision decision =
          decide(PlaybackFailureKind.temporarySource);

      expect(decision.step, PlaybackRecoveryStep.retry);
      expect(decision.delay, policy.retryDelay);
    });

    test('once the retry is spent, the queue moves on', () {
      final PlaybackFailureStreak streak = PlaybackFailureStreak()..noteRetry();

      final PlaybackRecoveryDecision decision =
          decide(PlaybackFailureKind.temporarySource, streak: streak);

      expect(decision.step, PlaybackRecoveryStep.advance);
      expect(decision.delay, policy.advanceDelay);
    });

    test('failures that a retry cannot fix move on without one', () {
      for (final PlaybackFailureKind kind in <PlaybackFailureKind>[
        PlaybackFailureKind.sourceSignInRequired,
        PlaybackFailureKind.unplayableMedia,
        PlaybackFailureKind.localFileUnavailable,
      ]) {
        expect(decide(kind).step, PlaybackRecoveryStep.advance,
            reason: kind.name);
      }
    });

    test('an engine failure settles at once: every track would fail the same',
        () {
      expect(
        decide(PlaybackFailureKind.playbackEngineUnavailable).step,
        PlaybackRecoveryStep.settle,
      );
    });

    test('later failures in a streak are not retried, only moved past', () {
      final PlaybackFailureStreak streak = PlaybackFailureStreak()
        ..noteRetry()
        ..record('jellyfin:a');

      final PlaybackRecoveryDecision decision = decide(
        PlaybackFailureKind.temporarySource,
        failed: 'jellyfin:b',
        next: 'jellyfin:c',
        streak: streak,
      );

      expect(decision.step, PlaybackRecoveryStep.advance);
    });

    test('settles with nowhere to go', () {
      expect(
        decide(PlaybackFailureKind.unplayableMedia, next: null).step,
        PlaybackRecoveryStep.settle,
      );
    });

    test('settles when the queue comes round to a track that already failed',
        () {
      // Repeat-all with a dead server: the wrap target failed earlier in this
      // same streak, so going round again would only fail it again.
      final PlaybackFailureStreak streak = PlaybackFailureStreak()
        ..noteRetry()
        ..record('jellyfin:a')
        ..record('jellyfin:b');

      expect(
        decide(
          PlaybackFailureKind.temporarySource,
          failed: 'jellyfin:c',
          next: 'jellyfin:a',
          streak: streak,
        ).step,
        PlaybackRecoveryStep.settle,
      );
      // A one-track repeat-all queue wraps onto itself.
      expect(
        decide(
          PlaybackFailureKind.unplayableMedia,
          failed: 'jellyfin:a',
          next: 'jellyfin:a',
        ).step,
        PlaybackRecoveryStep.settle,
      );
    });

    test('settles once the consecutive-failure cap is reached', () {
      final PlaybackFailureStreak streak = PlaybackFailureStreak()..noteRetry();
      for (int i = 0; i < policy.maxConsecutiveFailures - 1; i++) {
        streak.record('jellyfin:$i');
      }

      expect(
        decide(
          PlaybackFailureKind.temporarySource,
          failed: 'jellyfin:last',
          next: 'jellyfin:after',
          streak: streak,
        ).step,
        PlaybackRecoveryStep.settle,
      );
    });

    test('every automatic skip gets the same visible countdown', () {
      expect(policy.delayBeforeAdvance(1), const Duration(seconds: 5));
      expect(policy.delayBeforeAdvance(2), const Duration(seconds: 5));
      expect(policy.delayBeforeAdvance(50), const Duration(seconds: 5));
    });

    test('a policy that asks for it backs off between moves, capped', () {
      const PlaybackRecoveryPolicy backingOff = PlaybackRecoveryPolicy(
        advanceDelay: Duration(seconds: 1),
        maxAdvanceDelay: Duration(seconds: 8),
      );
      expect(backingOff.delayBeforeAdvance(1), const Duration(seconds: 1));
      expect(backingOff.delayBeforeAdvance(2), const Duration(seconds: 2));
      expect(backingOff.delayBeforeAdvance(3), const Duration(seconds: 4));
      expect(backingOff.delayBeforeAdvance(4), const Duration(seconds: 8));
      expect(backingOff.delayBeforeAdvance(50), const Duration(seconds: 8));
    });

    test('the whole walk is bounded in time as well as in tracks', () {
      Duration total = policy.retryDelay;
      for (int f = 1; f < policy.maxConsecutiveFailures; f++) {
        total += policy.delayBeforeAdvance(f);
      }
      expect(total, lessThanOrEqualTo(const Duration(seconds: 40)));
    });

    test('the retry waits out the provider reachability memory', () {
      // Otherwise the retry of a server that just failed would be answered
      // from memory with that same failure, without contacting the server.
      expect(
        policy.retryDelay,
        greaterThanOrEqualTo(CachingProviderReachability.defaultTtl),
      );
    });
  });

  group('PlaybackFailureStreak', () {
    test('tracks copies by uri, so two providers of one song stay apart', () {
      final PlaybackFailureStreak streak = PlaybackFailureStreak()
        ..record('jellyfin:101');

      expect(streak.contains('jellyfin:101'), isTrue);
      expect(streak.contains('subsonic:101'), isFalse);
    });

    test('clear starts over, retry included', () {
      final PlaybackFailureStreak streak = PlaybackFailureStreak()
        ..noteRetry()
        ..record('jellyfin:a');

      streak.clear();

      expect(streak.isEmpty, isTrue);
      expect(streak.retrySpent, isFalse);
    });
  });
}
