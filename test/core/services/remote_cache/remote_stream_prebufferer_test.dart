import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_index.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';
import 'package:linthra/core/services/remote_cache/remote_playback_cache.dart';
import 'package:linthra/core/services/remote_cache/remote_stream_prebufferer.dart';

import 'fake_remote_cache_store.dart';
import 'fake_stream_resolver.dart';

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');
Track _plex(String id) => Track(id: id, title: id, uri: 'plex:$id');
Track _local(String id) => Track(id: id, title: id, uri: '/music/$id.mp3');
Track _saf(String id) =>
    Track(id: id, title: id, uri: 'content://media/external/audio/media/$id');

void main() {
  final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);

  group('RemoteStreamPrebufferer.preload', () {
    test('warms a remote URL into the shared cache', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );

      await prebufferer.preload(_jellyfin('a'));

      expect(inner.resolved, <String>['a']);
      expect(cache.contains(RemoteCacheKey.forUri('jellyfin:a')!, now), isTrue);
    });

    test('routes Jellyfin, Plex and Subsonic tracks (all are cached)',
        () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );

      await prebufferer.preload(_jellyfin('j'));
      await prebufferer.preload(_subsonic('s'));
      await prebufferer.preload(_plex('1'));

      expect(inner.resolved, <String>['j', 's', '1']);
      expect(cache.length, 3);
    });

    test('a local file is never prebuffered (no remote cache)', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer =
          RemoteStreamPrebufferer(resolver: inner, cache: cache);

      await prebufferer.preload(_local('a'));

      expect(inner.resolved, isEmpty); // never even resolved
      expect(cache.length, 0);
    });

    test('a content:// (SAF) document is never prebuffered', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer =
          RemoteStreamPrebufferer(resolver: inner, cache: cache);

      await prebufferer.preload(_saf('42'));

      expect(inner.resolved, isEmpty);
      expect(cache.length, 0);
    });

    test('a non-stream resolution is never cached', () async {
      // If the inner reports a local/cache source for a "remote" track, the
      // prebufferer must not retain it — only direct stream URLs are held.
      final FakeStreamResolver inner =
          FakeStreamResolver(source: PlaybackSource.localFile);
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );

      await prebufferer.preload(_jellyfin('a'));

      expect(inner.resolved, <String>['a']); // it did resolve
      expect(cache.length, 0); // but stored nothing
    });

    test('swallows inner errors and caches nothing (non-fatal)', () async {
      final FakeStreamResolver inner = FakeStreamResolver(fail: true);
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer =
          RemoteStreamPrebufferer(resolver: inner, cache: cache);

      // Must not throw despite the inner failing.
      await prebufferer.preload(_jellyfin('a'));

      expect(inner.resolved, <String>['a']);
      expect(cache.length, 0);
    });

    test('does not re-resolve when a fresh entry already exists', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );
      final Track track = _jellyfin('a');

      await prebufferer.preload(track);
      await prebufferer.preload(track);
      await prebufferer.preload(track);

      expect(inner.resolved, <String>['a']); // one resolve, idempotent
    });
  });

  group('RemoteStreamPrebufferer.prepare (aggressive current + next)', () {
    test('warms the current track and the next item ahead', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );

      await prebufferer.prepare(
        current: _jellyfin('cur'),
        upNext: <Track>[_jellyfin('next'), _jellyfin('later')],
        ahead: 1,
      );

      // Current + exactly one ahead (not the whole queue).
      expect(inner.resolved, <String>['cur', 'next']);
      expect(
          cache.contains(RemoteCacheKey.forUri('jellyfin:cur')!, now), isTrue);
      expect(
        cache.contains(RemoteCacheKey.forUri('jellyfin:next')!, now),
        isTrue,
      );
      expect(
        cache.contains(RemoteCacheKey.forUri('jellyfin:later')!, now),
        isFalse,
      );
    });

    test('ahead can warm more than one upcoming item', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );

      await prebufferer.prepare(
        current: _jellyfin('cur'),
        upNext: <Track>[_jellyfin('n1'), _jellyfin('n2'), _jellyfin('n3')],
        ahead: 2,
      );

      expect(inner.resolved, <String>['cur', 'n1', 'n2']);
    });

    test('a local current track is skipped but a remote next is still warmed',
        () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );

      await prebufferer.prepare(
        current: _local('cur'),
        upNext: <Track>[_jellyfin('next')],
        ahead: 1,
      );

      expect(inner.resolved, <String>['next']);
    });

    test('prepare with nothing to warm is a no-op and never throws', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer =
          RemoteStreamPrebufferer(resolver: inner, cache: cache);

      await prebufferer.prepare();

      expect(inner.resolved, isEmpty);
    });
  });

  group('credential safety', () {
    test('a warmed entry never persists a token in its key or metadata',
        () async {
      final FakeStreamResolver inner =
          FakeStreamResolver(token: 'SUPER-SECRET');
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );
      final RemoteCacheKey key = RemoteCacheKey.forUri('plex:101')!;

      await prebufferer.preload(_plex('101'));
      final entry = cache.peek(key, now)!;

      // The token IS in the in-memory stream URL (that is allowed) ...
      expect(entry.streamUri.toString(), contains('SUPER-SECRET'));
      // ... but never in any of the persistable / loggable surfaces.
      for (final String s in <String>[
        entry.key.value,
        entry.key.fileSafeName,
        entry.key.toString(),
        entry.diagnosticLabel,
      ]) {
        expect(s, isNot(contains('SUPER-SECRET')));
        expect(s.toLowerCase(), isNot(contains('token')));
      }
    });
  });

  group('durable index integration', () {
    test('a warmed remote track is recorded in the durable index', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        index: index,
        clock: () => now,
      );

      await prebufferer.preload(_jellyfin('a'));

      expect(index.records.single.value, 'jellyfin:a');
      expect(store.saved.single.value, 'jellyfin:a');
    });

    test('records Jellyfin, Subsonic and Plex but never local/content tracks',
        () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        index: index,
        clock: () => now,
      );

      await prebufferer.prepare(
        current: _jellyfin('j'),
        upNext: <Track>[_subsonic('s'), _plex('1'), _local('x'), _saf('y')],
        ahead: 4,
      );

      expect(
        index.records.map((RemoteCacheRecord r) => r.value).toSet(),
        <String>{'jellyfin:j', 'subsonic:s', 'plex:1'},
      );
    });

    test('a non-stream resolution is not recorded', () async {
      final FakeStreamResolver inner =
          FakeStreamResolver(source: PlaybackSource.localFile);
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        index: index,
        clock: () => now,
      );

      await prebufferer.preload(_jellyfin('a'));

      expect(index.length, 0);
    });

    test('a failing index never breaks prebuffering (non-fatal)', () async {
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(failOnSave: true);
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        index: index,
        clock: () => now,
      );

      // Must not throw despite the index's store rejecting every write ...
      await prebufferer.preload(_jellyfin('a'));

      // ... and the in-memory warm still happened.
      expect(cache.contains(RemoteCacheKey.forUri('jellyfin:a')!, now), isTrue);
    });

    test('without an index the warm still works (back-compat)', () async {
      // The index is optional; existing wiring passes none and is unchanged.
      final FakeStreamResolver inner = FakeStreamResolver();
      final RemotePlaybackCache cache = RemotePlaybackCache();
      final RemoteStreamPrebufferer prebufferer = RemoteStreamPrebufferer(
        resolver: inner,
        cache: cache,
        clock: () => now,
      );

      await prebufferer.preload(_jellyfin('a'));

      expect(cache.contains(RemoteCacheKey.forUri('jellyfin:a')!, now), isTrue);
    });
  });
}
