import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/local_network/local_network_access.dart';
import 'package:linthra/core/services/local_network/local_network_permission.dart';
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

/// An inner resolver whose calls stay open until the test answers them, in any
/// order, so two attempts can overlap the way a request stuck on a dead network
/// and a later retry do.
class _AnsweredInner implements PlayableUriResolver {
  final List<Completer<ResolvedPlayable>> calls =
      <Completer<ResolvedPlayable>>[];

  @override
  bool handles(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<ResolvedPlayable> resolve(Track track) {
    final Completer<ResolvedPlayable> call = Completer<ResolvedPlayable>();
    calls.add(call);
    return call.future;
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
  void Function(ReachabilityStatus status)? onReachabilityObserved,
}) {
  return ReachabilityAwarePlayableUriResolver(
    inner: inner,
    providerKey: providerKey ?? () => 'jellyfin',
    reachability: reachability,
    connectivity: connectivity,
    onReachabilityObserved: onReachabilityObserved,
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

    test(
        'an attempt older than one that reached the server neither records '
        'nor reports its outage', () async {
      // Wi-Fi drops under a request, which hangs until the client times out.
      // Meanwhile the phone moves to mobile data and a newer attempt reaches
      // the server. The old request's verdict predates that answer, so it must
      // not leave the server remembered, or shown, as unreachable.
      final reachability = CachingProviderReachability();
      final observed = <ReachabilityStatus>[];
      final inner = _AnsweredInner();
      final resolver = _build(
        inner: inner,
        reachability: reachability,
        onReachabilityObserved: observed.add,
      );

      final Future<void> stale = expectLater(
        resolver.resolve(_track),
        throwsA(isA<PlaybackResolutionException>()),
      );
      final Future<ResolvedPlayable> newer = resolver.resolve(_track);
      await pumpEventQueue();
      expect(inner.calls, hasLength(2));

      inner.calls[1].complete(ResolvedPlayable(
        Uri.parse('https://stream/t1'),
        PlaybackSource.streamingDirect,
      ));
      await newer;
      inner.calls[0].completeError(const PlaybackResolutionException(
        'timed out',
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      ));
      await stale;

      expect(reachability.statusOf('jellyfin'), ReachabilityStatus.reachable);
      expect(observed, <ReachabilityStatus>[ReachabilityStatus.reachable]);
    });

    group('reachability observer', () {
      test('reports a successful resolve as reachable', () async {
        final observed = <ReachabilityStatus>[];
        final resolver = _build(
          inner: _FakeInner(),
          reachability: CachingProviderReachability(),
          onReachabilityObserved: observed.add,
        );

        await resolver.resolve(_track);

        expect(observed, <ReachabilityStatus>[ReachabilityStatus.reachable]);
      });

      test('reports a server-level failure so the library can hide the source',
          () async {
        final observed = <ReachabilityStatus>[];
        final resolver = _build(
          inner: _FakeInner(
              failWith: PlaybackResolutionErrorKind.serverUnreachable),
          reachability: CachingProviderReachability(),
          onReachabilityObserved: observed.add,
        );

        await expectLater(
          resolver.resolve(_track),
          throwsA(isA<PlaybackResolutionException>()),
        );

        expect(observed,
            <ReachabilityStatus>[ReachabilityStatus.serverUnreachable]);
      });

      test('reports an expired session as an auth failure, not an outage',
          () async {
        final observed = <ReachabilityStatus>[];
        final resolver = _build(
          inner:
              _FakeInner(failWith: PlaybackResolutionErrorKind.sessionExpired),
          reachability: CachingProviderReachability(),
          onReachabilityObserved: observed.add,
        );

        await expectLater(
          resolver.resolve(_track),
          throwsA(isA<PlaybackResolutionException>()),
        );

        expect(observed, <ReachabilityStatus>[ReachabilityStatus.authFailure]);
      });

      test('stays silent for a track-specific failure', () async {
        // "This one track has no stream" says nothing about the server, so the
        // library must not hide the whole source over it.
        final observed = <ReachabilityStatus>[];
        final resolver = _build(
          inner: _FakeInner(
              failWith: PlaybackResolutionErrorKind.streamUnavailable),
          reachability: CachingProviderReachability(),
          onReachabilityObserved: observed.add,
        );

        await expectLater(
          resolver.resolve(_track),
          throwsA(isA<PlaybackResolutionException>()),
        );

        expect(observed, isEmpty);
      });

      test('stays silent for the remembered-outage fast-fail', () async {
        // Only live attempts teach anything; replaying a cached outage would
        // just re-assert what the observer already knows.
        final reachability = CachingProviderReachability()
          ..record('jellyfin', ReachabilityStatus.serverUnreachable);
        final observed = <ReachabilityStatus>[];
        final resolver = _build(
          inner: _FakeInner(),
          reachability: reachability,
          onReachabilityObserved: observed.add,
        );

        await expectLater(
          resolver.resolve(_track),
          throwsA(isA<PlaybackResolutionException>()),
        );

        expect(observed, isEmpty);
      });

      test('reports the device being offline', () async {
        final observed = <ReachabilityStatus>[];
        final resolver = _build(
          inner: _FakeInner(),
          reachability: CachingProviderReachability(),
          connectivity: _FakeConnectivity(NetworkStatus.offline),
          onReachabilityObserved: observed.add,
        );

        await expectLater(
          resolver.resolve(_track),
          throwsA(isA<PlaybackResolutionException>()),
        );

        expect(observed,
            <ReachabilityStatus>[ReachabilityStatus.networkUnavailable]);
      });

      test('an observer that throws never breaks playback', () async {
        final resolver = _build(
          inner: _FakeInner(),
          reachability: CachingProviderReachability(),
          onReachabilityObserved: (_) => throw StateError('observer bug'),
        );

        final ResolvedPlayable resolved = await resolver.resolve(_track);

        expect(resolved.source, PlaybackSource.streamingDirect);
      });
    });
  });

  // Android 17: a LAN server can't be reached without ACCESS_LOCAL_NETWORK. A
  // track from it must fail fast with the reason (not a 20 s connect timeout),
  // and must not mark the server down: it isn't, and hiding its library would
  // take away the very tracks the user taps to be asked again.
  group('a LAN server behind Android 17\'s local network permission', () {
    test('fails fast with the reason and leaves reachability alone', () async {
      final _FakeInner inner = _FakeInner();
      final CachingProviderReachability reachability =
          CachingProviderReachability();
      final List<ReachabilityStatus> observed = <ReachabilityStatus>[];
      final _ScriptedPermission permission =
          _ScriptedPermission(LocalNetworkPermissionStatus.denied);
      final ReachabilityAwarePlayableUriResolver resolver =
          ReachabilityAwarePlayableUriResolver(
        inner: inner,
        providerKey: () => 'jellyfin',
        reachability: reachability,
        onReachabilityObserved: observed.add,
        localNetwork: LocalNetworkAccess(
          permission: permission,
          isVpnUp: () async => false,
        ),
        serverUri: () => Uri.parse('http://192.168.1.20:8096'),
      );

      await expectLater(
        resolver.resolve(_track),
        throwsA(isA<PlaybackResolutionException>()
            .having((PlaybackResolutionException e) => e.kind, 'kind',
                PlaybackResolutionErrorKind.serverUnreachable)
            .having((PlaybackResolutionException e) => e.message, 'message',
                contains('local network'))),
      );
      expect(inner.calls, 0, reason: 'no doomed connection attempt');
      expect(reachability.statusOf('jellyfin'), isNull);
      expect(observed, isEmpty);
    });

    test('asks once while on screen, and plays once granted', () async {
      final _FakeInner inner = _FakeInner();
      final _ScriptedPermission permission = _ScriptedPermission(
        LocalNetworkPermissionStatus.notRequested,
        answer: LocalNetworkPermissionStatus.granted,
      );
      final ReachabilityAwarePlayableUriResolver resolver =
          ReachabilityAwarePlayableUriResolver(
        inner: inner,
        providerKey: () => 'jellyfin',
        reachability: CachingProviderReachability(),
        localNetwork: LocalNetworkAccess(
          permission: permission,
          isVpnUp: () async => false,
        ),
        serverUri: () => Uri.parse('http://192.168.1.20:8096'),
      );

      final ResolvedPlayable played = await resolver.resolve(_track);
      expect(played.uri.toString(), 'https://stream/t1');
      expect(permission.requests, 1);
      await resolver.resolve(_track);
      expect(permission.requests, 1);
    });

    test('an internet server is untouched by it', () async {
      final _FakeInner inner = _FakeInner();
      final _ScriptedPermission permission =
          _ScriptedPermission(LocalNetworkPermissionStatus.permanentlyDenied);
      final ReachabilityAwarePlayableUriResolver resolver =
          ReachabilityAwarePlayableUriResolver(
        inner: inner,
        providerKey: () => 'jellyfin',
        reachability: CachingProviderReachability(),
        localNetwork: LocalNetworkAccess(
          permission: permission,
          isVpnUp: () async => false,
        ),
        serverUri: () => Uri.parse('https://203.0.113.7'),
      );
      await resolver.resolve(_track);
      expect(inner.calls, 1);
    });
  });
}

class _ScriptedPermission implements LocalNetworkPermission {
  _ScriptedPermission(this.current, {this.answer});

  LocalNetworkPermissionStatus current;
  final LocalNetworkPermissionStatus? answer;
  int requests = 0;

  @override
  Future<LocalNetworkPermissionStatus> status() async => current;

  @override
  Future<LocalNetworkPermissionStatus> request() async {
    requests++;
    current = answer ?? current;
    return current;
  }

  @override
  Future<void> openAppSettings() async {}
}
