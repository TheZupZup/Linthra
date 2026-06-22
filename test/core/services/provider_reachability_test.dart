import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/provider_reachability.dart';
import 'package:linthra/core/services/reachability.dart';

void main() {
  group('CachingProviderReachability', () {
    test('an unknown key has no remembered status', () {
      final reachability = CachingProviderReachability();
      expect(reachability.statusOf('jellyfin'), isNull);
    });

    test('a recorded status is remembered within its TTL', () {
      DateTime now = DateTime(2026, 6, 22, 12, 0, 0);
      final reachability = CachingProviderReachability(
        ttl: const Duration(seconds: 10),
        clock: () => now,
      );

      reachability.record('jellyfin', ReachabilityStatus.serverUnreachable);

      now = now.add(const Duration(seconds: 9));
      expect(
        reachability.statusOf('jellyfin'),
        ReachabilityStatus.serverUnreachable,
      );
    });

    test('a remembered status ages out after the TTL — so retry works', () {
      // This is what makes "retry after connectivity returns" automatic: once
      // the brief memory expires, the next attempt probes for a fresh answer
      // rather than staying stuck on the old failure.
      DateTime now = DateTime(2026, 6, 22, 12, 0, 0);
      final reachability = CachingProviderReachability(
        ttl: const Duration(seconds: 10),
        clock: () => now,
      );

      reachability.record('jellyfin', ReachabilityStatus.serverUnreachable);
      now = now.add(const Duration(seconds: 10));

      expect(reachability.statusOf('jellyfin'), isNull);
    });

    test('a later success overwrites an earlier outage immediately', () {
      DateTime now = DateTime(2026, 6, 22, 12, 0, 0);
      final reachability = CachingProviderReachability(clock: () => now);

      reachability.record('plex', ReachabilityStatus.serverUnreachable);
      now = now.add(const Duration(seconds: 2));
      reachability.record('plex', ReachabilityStatus.reachable);

      expect(reachability.statusOf('plex'), ReachabilityStatus.reachable);
    });

    test('per-provider keys stay isolated (same bare id, different provider)',
        () {
      // jellyfin:101 and subsonic:101 share a server-side id but are different
      // providers. Marking one unreachable must never suppress the other.
      final reachability = CachingProviderReachability();

      reachability.record('jellyfin', ReachabilityStatus.serverUnreachable);

      expect(
        reachability.statusOf('jellyfin'),
        ReachabilityStatus.serverUnreachable,
      );
      expect(reachability.statusOf('subsonic'), isNull);
    });

    test('forget drops a single provider without touching others', () {
      final reachability = CachingProviderReachability();
      reachability.record('jellyfin', ReachabilityStatus.serverUnreachable);
      reachability.record('subsonic', ReachabilityStatus.reachable);

      reachability.forget('jellyfin');

      expect(reachability.statusOf('jellyfin'), isNull);
      expect(reachability.statusOf('subsonic'), ReachabilityStatus.reachable);
    });

    test('clear drops every remembered status', () {
      final reachability = CachingProviderReachability();
      reachability.record('jellyfin', ReachabilityStatus.serverUnreachable);
      reachability.record('plex', ReachabilityStatus.timeout);

      reachability.clear();

      expect(reachability.statusOf('jellyfin'), isNull);
      expect(reachability.statusOf('plex'), isNull);
    });
  });
}
