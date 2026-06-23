import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/reachability.dart';

void main() {
  group('ReachabilityStatus', () {
    test('isReachable is true only for reachable', () {
      expect(ReachabilityStatus.reachable.isReachable, isTrue);
      for (final ReachabilityStatus s in ReachabilityStatus.values) {
        if (s != ReachabilityStatus.reachable) {
          expect(s.isReachable, isFalse, reason: '$s');
        }
      }
    });

    test('isOffline is true only for networkUnavailable', () {
      expect(ReachabilityStatus.networkUnavailable.isOffline, isTrue);
      expect(ReachabilityStatus.serverUnreachable.isOffline, isFalse);
      expect(ReachabilityStatus.authFailure.isOffline, isFalse);
    });

    test('an auth failure is kept distinct from the offline states', () {
      // The whole point of the enum: "server rejected the session" must never be
      // confused with "couldn't reach the server" — they need different fixes.
      const ReachabilityStatus auth = ReachabilityStatus.authFailure;
      expect(auth.isAuthFailure, isTrue);
      expect(auth.isOffline, isFalse);
      expect(auth.isReachable, isFalse);
      // And crucially it is NOT a cacheable server outage, so it is never cached
      // as "don't bother retrying" — a fresh sign-in must work immediately.
      expect(auth.isServerOutage, isFalse);
    });

    test('the server-outage states are exactly server-unreachable and timeout',
        () {
      // Only these two are worth caching as "skip the probe for a moment".
      expect(ReachabilityStatus.serverUnreachable.isServerOutage, isTrue);
      expect(ReachabilityStatus.timeout.isServerOutage, isTrue);
      // networkUnavailable is device-global (judged fresh, never cached);
      // reachable and authFailure are not outages — all three are excluded.
      expect(ReachabilityStatus.networkUnavailable.isServerOutage, isFalse);
      expect(ReachabilityStatus.reachable.isServerOutage, isFalse);
      expect(ReachabilityStatus.authFailure.isServerOutage, isFalse);
    });
  });

  group('reachabilityFromPlaybackError', () {
    test('maps an unreachable server to a server-unreachable outage', () {
      expect(
        reachabilityFromPlaybackError(
          PlaybackResolutionErrorKind.serverUnreachable,
        ),
        ReachabilityStatus.serverUnreachable,
      );
    });

    test('maps an expired session to an auth failure, not an outage', () {
      // Separation of concerns: a session problem must classify as authFailure
      // so the offline fast-fail path never swallows it.
      expect(
        reachabilityFromPlaybackError(
          PlaybackResolutionErrorKind.sessionExpired,
        ),
        ReachabilityStatus.authFailure,
      );
    });

    test('returns null for track-specific or not-signed-in failures', () {
      // These say nothing reliable about whether the *server* is reachable, so
      // they must not poison the provider-wide reachability memory.
      for (final PlaybackResolutionErrorKind kind
          in <PlaybackResolutionErrorKind>[
        PlaybackResolutionErrorKind.notSignedIn,
        PlaybackResolutionErrorKind.invalidStream,
        PlaybackResolutionErrorKind.serverReturnedWebPage,
        PlaybackResolutionErrorKind.streamUnavailable,
      ]) {
        expect(reachabilityFromPlaybackError(kind), isNull, reason: '$kind');
      }
    });
  });
}
