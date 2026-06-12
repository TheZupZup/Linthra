import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_policy.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_resolver.dart';
import 'package:linthra/core/services/remote_cache/remote_playback_cache.dart';
import 'package:linthra/core/services/remote_cache/remote_stream_prebufferer.dart';

import 'fake_stream_resolver.dart';

Track _remote(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _local(String id) => Track(id: id, title: id, uri: '/music/$id.mp3');

void main() {
  group('RemoteCacheResolver', () {
    test('serves a prebuffered URL once, without re-resolving', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer =
          RemoteStreamPrebufferer(resolver: inner, cache: cache);
      final RemoteCacheResolver resolver =
          RemoteCacheResolver(inner: inner, cache: cache);
      final Track track = _remote('a');

      await prebufferer.preload(track);
      expect(inner.resolved, <String>['a']); // warmed once

      final ResolvedPlayable served = await resolver.resolve(track);
      // Served from the warm cache — the inner resolver was NOT called again.
      expect(inner.resolved, <String>['a']);
      expect(served.uri.toString(), contains('n=1'));
      expect(served.source, PlaybackSource.streamingDirect);
    });

    test('a second resolve re-resolves fresh (consume-on-read)', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer =
          RemoteStreamPrebufferer(resolver: inner, cache: cache);
      final RemoteCacheResolver resolver =
          RemoteCacheResolver(inner: inner, cache: cache);
      final Track track = _remote('a');

      await prebufferer.preload(track);
      await resolver.resolve(track); // consumes the warm entry (n=1)
      final ResolvedPlayable second = await resolver.resolve(track); // n=2

      expect(inner.resolved, <String>['a', 'a']);
      expect(second.uri.toString(), contains('n=2'));
    });

    test('a local track always falls through to the inner resolver', () async {
      // A local track has no cache key, so it is never served from the cache —
      // it always delegates straight to the inner resolver.
      final FakeStreamResolver inner =
          FakeStreamResolver(source: PlaybackSource.localFile);
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteCacheResolver resolver =
          RemoteCacheResolver(inner: inner, cache: cache);

      final ResolvedPlayable resolved = await resolver.resolve(_local('a'));

      expect(inner.resolved, <String>['a']);
      expect(resolved.uri.scheme, 'file');
      expect(resolved.source, PlaybackSource.localFile);
    });

    test('an expired warm entry is ignored and re-resolved fresh', () async {
      DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        policy: const RemoteCachePolicy(ttl: Duration(minutes: 2)),
        clock: () => now,
      );
      final RemoteCacheResolver resolver = RemoteCacheResolver(
        inner: inner,
        cache: cache,
        clock: () => now,
      );
      final Track track = _remote('a');

      await prebufferer.preload(track); // warmed at 12:00, expires 12:02
      now = DateTime(2026, 1, 1, 12, 5, 0); // 5 minutes later: expired

      final ResolvedPlayable resolved = await resolver.resolve(track);
      // Stale entry dropped; resolved fresh from the inner resolver.
      expect(inner.resolved, <String>['a', 'a']);
      expect(resolved.uri.toString(), contains('n=2'));
    });

    test('resolve without a warm entry delegates straight to the inner',
        () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteCacheResolver resolver =
          RemoteCacheResolver(inner: inner, cache: cache);

      final ResolvedPlayable resolved = await resolver.resolve(_remote('a'));

      expect(inner.resolved, <String>['a']);
      expect(resolved.source, PlaybackSource.streamingDirect);
    });
  });
}
