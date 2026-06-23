import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/provider_reachability.dart';
import 'package:linthra/core/services/reachability.dart';
import 'package:linthra/core/services/reachability_aware_playable_uri_resolver.dart';

/// An inner resolver that either returns a canned stream URL or throws a given
/// failure kind, counting how many times it was actually invoked so a test can
/// prove a fast-fail skipped the (doomed) probe.
class _FakeInner implements PlayableUriResolver {
  _FakeInner({this.failWith});

  /// When non-null, every resolve throws this kind; otherwise it succeeds.
  final PlaybackResolutionErrorKind? failWith;
  int calls = 0;

  @override
  bool handles(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls++;
    final PlaybackResolutionErrorKind? kind = failWith;
    if (kind != null) {
      throw PlaybackResolutionException('inner failed', kind: kind);
    }
    return ResolvedPlayable(
      Uri.parse('https://stream/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

/// A connectivity service whose status a test can flip, to simulate the network
/// dropping and returning between resolve calls.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity(this.status);

  NetworkStatus status;

  @override
  Stream<NetworkStatus> get statusStream => Stream<NetworkStatus>.value(status);

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

const Track _track = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

ReachabilityAwarePlayableUriResolver _build({
  required PlayableUriResolver inner,
  required ProviderReachability reachability,
  String? Function()? providerKey,
  ConnectivityService? connectivity,
}) {
  return ReachabilityAwarePlayableUriResolver(
    inner: inner,
    providerKey: providerKey ?? () => 'jellyfin',
    reachability: reachability,
    connectivity: connectivity,
  );
}

void main() {
  group('ReachabilityAwarePlayableUriResolver', () {
    test('handles delegates to the inner resolver', () {
      final resolver = _build(
        inner: _FakeInner(),
        reachability: CachingProviderReachability(),
      );
      expect(resolver.handles(_track), isTrue);
      expect(
        resolver.handles(const Track(id: 'x', title: 'X', uri: 'subsonic:x')),
        isFalse,
      );
    });

    test('a successful resolve passes through and records reachable', () async {
      final reachability = CachingProviderReachability();
      final inner = _FakeInner();
      final resolver = _build(inner: inner, reachability: reachability);

      final ResolvedPlayable resolved = await resolver.resolve(_track);

      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(reachability.statusOf('jellyfin'), ReachabilityStatus.reachable);
    });

    test('an unreachable failure is recorded and rethrown', () async {
      final reachability = CachingProviderReachability();
      final inner = _FakeInner(
        failWith: PlaybackResolutionErrorKind.serverUnreachable,
      );
      final resolver = _build(inner: inner, reachability: reachability);

      await expectLater(
        resolver.resolve(_track),
        throwsA(isA<PlaybackResolutionException>().having(
          (PlaybackResolutionException e) => e.kind,
          'kind',
          PlaybackResolutionErrorKind.serverUnreachable,
        )),
      );
      expect(
        reachability.statusOf('jellyfin'),
        ReachabilityStatus.serverUnreachable,
      );
    });

    test(
        'once unreachable is remembered, the next resolve fails fast (no probe)',
        () async {
      // The core anti-stall behavior: a server that just failed isn't probed
      // again for every following track — the second attempt skips the inner
      // resolver entirely and falls straight through to the caller's fallback.
      final reachability = CachingProviderReachability();
      final inner = _FakeInner(
        failWith: PlaybackResolutionErrorKind.serverUnreachable,
      );
      final resolver = _build(inner: inner, reachability: reachability);

      await expectLater(resolver.resolve(_track), throwsA(anything));
      expect(inner.calls, 1);

      // Second attempt: still throws serverUnreachable, but without touching the
      // network again.
      await expectLater(
        resolver.resolve(_track),
        throwsA(isA<PlaybackResolutionException>().having(
          (PlaybackResolutionException e) => e.kind,
          'kind',
          PlaybackResolutionErrorKind.serverUnreachable,
        )),
      );
      expect(inner.calls, 1, reason: 'the second resolve must skip the probe');
    });

    test('an auth failure is recorded but never fast-failed', () async {
      // A session problem must keep probing: the moment the user re-signs-in, a
      // fresh request has to be attempted, so an auth failure is never cached as
      // "don't bother". It also classifies as authFailure, not an outage.
      final reachability = CachingProviderReachability();
      final inner = _FakeInner(
        failWith: PlaybackResolutionErrorKind.sessionExpired,
      );
      final resolver = _build(inner: inner, reachability: reachability);

      await expectLater(resolver.resolve(_track), throwsA(anything));
      expect(reachability.statusOf('jellyfin'), ReachabilityStatus.authFailure);

      // Second attempt still probes (no fast-fail), so a recovered session works.
      await expectLater(resolver.resolve(_track), throwsA(anything));
      expect(inner.calls, 2, reason: 'auth failures must not suppress retries');
    });

    test('a recovered server (cache says reachable) is probed normally',
        () async {
      final reachability = CachingProviderReachability()
        ..record('jellyfin', ReachabilityStatus.reachable);
      final inner = _FakeInner();
      final resolver = _build(inner: inner, reachability: reachability);

      await resolver.resolve(_track);

      expect(inner.calls, 1);
    });

    test('offline short-circuits to a clear error without probing', () async {
      // Network unavailable: don't attempt a connection that can only time out.
      final reachability = CachingProviderReachability();
      final inner = _FakeInner();
      final resolver = _build(
        inner: inner,
        reachability: reachability,
        connectivity: _FakeConnectivity(NetworkStatus.offline),
      );

      await expectLater(
        resolver.resolve(_track),
        throwsA(isA<PlaybackResolutionException>()
            .having(
              (PlaybackResolutionException e) => e.kind,
              'kind',
              PlaybackResolutionErrorKind.serverUnreachable,
            )
            .having(
              (PlaybackResolutionException e) => e.message,
              'message',
              contains('offline'),
            )),
      );
      expect(inner.calls, 0, reason: 'offline must not hit the network');
      // Device-offline is judged fresh and never cached, so it doesn't poison
      // the per-server memory — a reconnect probes straight away (next test).
      expect(reachability.statusOf('jellyfin'), isNull);
    });

    test(
        'a reconnect probes immediately, not blocked by a prior offline result',
        () async {
      // Regression guard: once offline and then online again, the next resolve
      // must probe the recovered server rather than replay a stale "offline" for
      // the cache's lifetime.
      final reachability = CachingProviderReachability();
      final inner = _FakeInner();
      final connectivity = _FakeConnectivity(NetworkStatus.offline);
      final resolver = _build(
        inner: inner,
        reachability: reachability,
        connectivity: connectivity,
      );

      // Offline: fails fast without probing.
      await expectLater(resolver.resolve(_track), throwsA(anything));
      expect(inner.calls, 0);

      // Network returns: the very next resolve probes and succeeds.
      connectivity.status = NetworkStatus.wifi;
      final ResolvedPlayable resolved = await resolver.resolve(_track);
      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(inner.calls, 1);
    });

    test('does not crash and resolves normally when network is available',
        () async {
      final reachability = CachingProviderReachability();
      final inner = _FakeInner();
      final resolver = _build(
        inner: inner,
        reachability: reachability,
        connectivity: _FakeConnectivity(NetworkStatus.wifi),
      );

      final ResolvedPlayable resolved = await resolver.resolve(_track);

      expect(resolved.source, PlaybackSource.streamingDirect);
    });

    test('with no session (null key) it delegates without caching', () async {
      final reachability = CachingProviderReachability();
      final inner = _FakeInner(
        failWith: PlaybackResolutionErrorKind.notSignedIn,
      );
      final resolver = _build(
        inner: inner,
        reachability: reachability,
        providerKey: () => null,
      );

      await expectLater(resolver.resolve(_track), throwsA(anything));
      // Nothing is cached for a signed-out provider, and the inner answer (not
      // signed in) is surfaced unchanged.
      expect(reachability.statusOf('jellyfin'), isNull);
    });

    test('a remembered jellyfin outage never fast-fails a subsonic resolve',
        () async {
      // Two decorators sharing one reachability memory, keyed per provider. A
      // jellyfin outage must not suppress the subsonic copy of a same-bare-id
      // song (jellyfin:101 vs subsonic:101).
      final reachability = CachingProviderReachability();
      final jellyInner = _FakeInner(
        failWith: PlaybackResolutionErrorKind.serverUnreachable,
      );
      final subInner = _FakeInner();
      final jelly = ReachabilityAwarePlayableUriResolver(
        inner: jellyInner,
        providerKey: () => 'jellyfin',
        reachability: reachability,
      );
      final sub = ReachabilityAwarePlayableUriResolver(
        inner: subInner,
        providerKey: () => 'subsonic',
        reachability: reachability,
      );
      const Track j101 = Track(id: '101', title: 'X', uri: 'jellyfin:101');
      const Track s101 = Track(id: '101', title: 'X', uri: 'subsonic:101');

      await expectLater(jelly.resolve(j101), throwsA(anything));

      // Subsonic still resolves: its key has no remembered outage.
      final ResolvedPlayable resolved = await sub.resolve(s101);
      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(subInner.calls, 1);
    });
  });
}
