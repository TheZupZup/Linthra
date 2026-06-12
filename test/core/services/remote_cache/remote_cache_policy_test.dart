import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_policy.dart';

Track _track(String uri) => Track(id: uri, title: 't', uri: uri);

void main() {
  group('RemoteCachePolicy', () {
    const RemoteCachePolicy policy = RemoteCachePolicy();

    test('only remote tracks are prebufferable', () {
      expect(policy.isPrebufferable(_track('jellyfin:a')), isTrue);
      expect(policy.isPrebufferable(_track('subsonic:b')), isTrue);
      expect(policy.isPrebufferable(_track('plex:1')), isTrue);
      expect(policy.isPrebufferable(_track('/music/a.mp3')), isFalse);
      expect(
        policy.isPrebufferable(_track('content://media/audio/1')),
        isFalse,
      );
    });

    test('only a direct stream resolution is storable', () {
      expect(policy.isStorable(PlaybackSource.streamingDirect), isTrue);
      // A local path or an offline-cache hit opens instantly / is owned by the
      // on-disk cache, so it must not be retained in the in-memory cache.
      expect(policy.isStorable(PlaybackSource.localFile), isFalse);
      expect(policy.isStorable(PlaybackSource.offlineCache), isFalse);
    });

    test('buildEntry stamps freshness from now + ttl', () {
      const RemoteCachePolicy ttl5 =
          RemoteCachePolicy(ttl: Duration(minutes: 5));
      final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
      final RemoteCacheEntry entry = ttl5.buildEntry(
        key: RemoteCacheKey.forUri('plex:1')!,
        resolved: ResolvedPlayable(
          Uri.parse('https://server.example/s?api_key=SECRET'),
          PlaybackSource.streamingDirect,
        ),
        now: now,
      );

      expect(entry.resolvedAt, now);
      expect(entry.expiresAt, now.add(const Duration(minutes: 5)));
      expect(entry.source, PlaybackSource.streamingDirect);
    });

    test('shouldReuse mirrors entry freshness', () {
      final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
      final RemoteCacheEntry entry = policy.buildEntry(
        key: RemoteCacheKey.forUri('plex:1')!,
        resolved: ResolvedPlayable(
          Uri.parse('https://server.example/s'),
          PlaybackSource.streamingDirect,
        ),
        now: now,
      );

      expect(policy.shouldReuse(entry, now), isTrue);
      expect(
        policy.shouldReuse(entry, now.add(const Duration(minutes: 3))),
        isFalse,
      );
    });
  });
}
