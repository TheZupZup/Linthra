import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_playback_cache.dart';

RemoteCacheEntry _entry(
  String uri, {
  required DateTime resolvedAt,
  required DateTime expiresAt,
  String streamUri = 'https://server.example/s?api_key=SECRET-TOKEN',
}) =>
    RemoteCacheEntry(
      key: RemoteCacheKey.forUri(uri)!,
      streamUri: Uri.parse(streamUri),
      source: PlaybackSource.streamingDirect,
      resolvedAt: resolvedAt,
      expiresAt: expiresAt,
    );

void main() {
  final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
  final RemoteCacheKey plex = RemoteCacheKey.forUri('plex:101')!;

  group('RemotePlaybackCache store / peek / consume', () {
    test('stores and peeks a fresh entry without consuming it', () {
      final RemotePlaybackCache cache = RemotePlaybackCache();
      cache.store(_entry('plex:101',
          resolvedAt: now, expiresAt: now.add(const Duration(minutes: 2))));

      expect(cache.contains(plex, now), isTrue);
      expect(cache.peek(plex, now), isNotNull);
      // Peek does not remove it.
      expect(cache.peek(plex, now), isNotNull);
    });

    test('consume returns the entry once, then it is gone', () {
      final RemotePlaybackCache cache = RemotePlaybackCache();
      cache.store(_entry('plex:101',
          resolvedAt: now, expiresAt: now.add(const Duration(minutes: 2))));

      expect(cache.consume(plex, now), isNotNull);
      // Consume-on-read: the second call is a miss, so a retry/replay
      // re-resolves a fresh URL rather than replaying a possibly-stale one.
      expect(cache.consume(plex, now), isNull);
      expect(cache.contains(plex, now), isFalse);
    });

    test('an expired entry is never served and is dropped on read', () {
      final RemotePlaybackCache cache = RemotePlaybackCache();
      cache.store(_entry('plex:101',
          resolvedAt: now, expiresAt: now.add(const Duration(minutes: 2))));
      final DateTime later = now.add(const Duration(minutes: 5));

      expect(cache.contains(plex, later), isFalse);
      expect(cache.peek(plex, later), isNull);
      expect(cache.consume(plex, later), isNull);
      expect(cache.length, 0); // peek/consume evicted the stale entry
    });

    test('the newest stored entry wins for a key', () {
      final RemotePlaybackCache cache = RemotePlaybackCache();
      cache.store(_entry('plex:101',
          resolvedAt: now,
          expiresAt: now.add(const Duration(minutes: 2)),
          streamUri: 'https://server.example/old'));
      cache.store(_entry('plex:101',
          resolvedAt: now,
          expiresAt: now.add(const Duration(minutes: 2)),
          streamUri: 'https://server.example/new'));

      expect(cache.consume(plex, now)!.streamUri.path, '/new');
    });
  });

  group('RemotePlaybackCache sweep / clear', () {
    test('sweep removes only stale entries', () {
      final RemotePlaybackCache cache = RemotePlaybackCache();
      cache.store(_entry('plex:fresh',
          resolvedAt: now, expiresAt: now.add(const Duration(minutes: 2))));
      cache.store(_entry('jellyfin:stale',
          resolvedAt: now.subtract(const Duration(minutes: 5)),
          expiresAt: now.subtract(const Duration(minutes: 3))));

      cache.sweep(now);

      expect(cache.length, 1);
      expect(cache.contains(RemoteCacheKey.forUri('plex:fresh')!, now), isTrue);
      expect(
        cache.contains(RemoteCacheKey.forUri('jellyfin:stale')!, now),
        isFalse,
      );
    });

    test('clear drops everything (e.g. on sign-out)', () {
      final RemotePlaybackCache cache = RemotePlaybackCache();
      cache.store(_entry('plex:101',
          resolvedAt: now, expiresAt: now.add(const Duration(minutes: 2))));
      cache.clear();
      expect(cache.length, 0);
    });
  });
}
