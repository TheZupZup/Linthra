import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/stream_preloading_resolver.dart';

/// A configurable inner resolver that records every `resolve` call, so a test
/// can prove when the decorator served a *cached* URL (no inner call) vs.
/// resolved fresh. By default it mints a fresh https stream URL per call; it can
/// be told to fail, or to report a non-stream (local) source.
class _FakeInnerResolver implements PlayableUriResolver {
  _FakeInnerResolver({
    this.source = PlaybackSource.streamingDirect,
    this.fail = false,
  });

  PlaybackSource source;
  bool fail;
  final List<String> resolved = <String>[];
  int _counter = 0;

  @override
  bool handles(Track track) =>
      track.uri.startsWith('jellyfin:') || track.uri.startsWith('subsonic:');

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    resolved.add(track.id);
    if (fail) {
      throw const PlaybackResolutionException(
        "Couldn't reach your server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    // A fresh, unique URL each time so a served-from-cache result is provably
    // the *preloaded* one, not a re-resolve.
    _counter++;
    return ResolvedPlayable(
      Uri.parse('https://x/${track.id}?n=$_counter'),
      source,
    );
  }
}

Track _remote(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _local(String id) => Track(id: id, title: id, uri: '/music/$id.mp3');

void main() {
  group('StreamPreloadingResolver', () {
    test('preload warms a remote URL that resolve then serves once', () async {
      final inner = _FakeInnerResolver();
      final resolver = StreamPreloadingResolver(inner);
      final track = _remote('a');

      await resolver.preload(track);
      expect(inner.resolved, <String>['a']); // warmed once

      final resolved = await resolver.resolve(track);
      // Served from the warm cache — the inner resolver was NOT called again.
      expect(inner.resolved, <String>['a']);
      expect(resolved.uri.toString(), contains('n=1'));
      expect(resolved.source, PlaybackSource.streamingDirect);
    });

    test('a second resolve re-resolves fresh (consume-on-read)', () async {
      // This is what lets a retry after a failed load get a *fresh* URL rather
      // than replaying a possibly-expired preloaded one.
      final inner = _FakeInnerResolver();
      final resolver = StreamPreloadingResolver(inner);
      final track = _remote('a');

      await resolver.preload(track);
      await resolver.resolve(track); // consumes the warm entry (n=1)
      final second = await resolver.resolve(track); // re-resolves (n=2)

      expect(inner.resolved, <String>['a', 'a']);
      expect(second.uri.toString(), contains('n=2'));
    });

    test('preload is a no-op for a local track', () async {
      final inner = _FakeInnerResolver();
      final resolver = StreamPreloadingResolver(inner);

      await resolver.preload(_local('a'));

      expect(inner.resolved, isEmpty); // local files need no warming
    });

    test('a non-stream resolution is never cached', () async {
      // If the inner ever reports a local/cache source for a "remote" track, the
      // decorator must not retain it — only short-lived stream URLs are held.
      final inner = _FakeInnerResolver(source: PlaybackSource.localFile);
      final resolver = StreamPreloadingResolver(inner);
      final track = _remote('a');

      // Preload resolves but won't cache (source != streamingDirect), so the
      // resolve must go back to the inner rather than serve a cached entry.
      await resolver.preload(track);
      await resolver.resolve(track);

      expect(inner.resolved, <String>['a', 'a']);
    });

    test('an expired warm entry is ignored (short-lived, in-memory only)',
        () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final inner = _FakeInnerResolver();
      final resolver = StreamPreloadingResolver(
        inner,
        ttl: const Duration(minutes: 2),
        clock: () => now,
      );
      final track = _remote('a');

      await resolver.preload(track); // warmed at 12:00, expires 12:02
      now = DateTime(2026, 1, 1, 12, 5, 0); // 5 minutes later: expired

      final resolved = await resolver.resolve(track);
      // Stale entry dropped; resolved fresh from the inner resolver.
      expect(inner.resolved, <String>['a', 'a']);
      expect(resolved.uri.toString(), contains('n=2'));
    });

    test('preload swallows inner errors and caches nothing', () async {
      final inner = _FakeInnerResolver(fail: true);
      final resolver = StreamPreloadingResolver(inner);
      final track = _remote('a');

      // Must not throw despite the inner failing.
      await resolver.preload(track);
      expect(inner.resolved, <String>['a']);

      // Nothing was cached, so a later resolve goes back to the inner (which now
      // succeeds once we stop failing) rather than serving a poisoned entry.
      inner.fail = false;
      final resolved = await resolver.resolve(track);
      expect(inner.resolved, <String>['a', 'a']);
      expect(resolved.source, PlaybackSource.streamingDirect);
    });

    test('preload does not re-resolve when a fresh entry already exists',
        () async {
      // Idempotent: rapid duplicate preload requests for the same track spend
      // only one resolve (and on LTE, only one tiny request).
      final inner = _FakeInnerResolver();
      final resolver = StreamPreloadingResolver(inner);
      final track = _remote('a');

      await resolver.preload(track);
      await resolver.preload(track);
      await resolver.preload(track);

      expect(inner.resolved, <String>['a']);
    });

    test('resolve without a preload delegates straight to the inner', () async {
      final inner = _FakeInnerResolver();
      final resolver = StreamPreloadingResolver(inner);

      final resolved = await resolver.resolve(_remote('a'));

      expect(inner.resolved, <String>['a']);
      expect(resolved.source, PlaybackSource.streamingDirect);
    });
  });
}
