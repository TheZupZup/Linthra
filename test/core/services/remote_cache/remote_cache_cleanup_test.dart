import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_cleanup.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';

RemoteCacheEntry _entry(String uri, DateTime expiresAt) => RemoteCacheEntry(
      key: RemoteCacheKey.forUri(uri)!,
      streamUri: Uri.parse('https://server.example/s'),
      source: PlaybackSource.streamingDirect,
      resolvedAt: expiresAt.subtract(const Duration(minutes: 2)),
      expiresAt: expiresAt,
    );

void main() {
  group('RemoteCacheCleanup', () {
    const RemoteCacheCleanup cleanup = RemoteCacheCleanup();
    final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);

    test('reports only the keys past their freshness window', () {
      final List<RemoteCacheEntry> entries = <RemoteCacheEntry>[
        _entry('jellyfin:fresh', now.add(const Duration(minutes: 1))),
        _entry('plex:stale', now.subtract(const Duration(minutes: 1))),
        _entry('subsonic:expiring-now', now),
      ];

      final List<String> expired = cleanup
          .expiredKeys(entries, now)
          .map((RemoteCacheKey k) => k.value)
          .toList();

      // The fresh one survives; the stale one and the one expiring exactly now
      // are dropped.
      expect(expired, containsAll(<String>['plex:stale', 'subsonic:expiring-now']));
      expect(expired, isNot(contains('jellyfin:fresh')));
    });

    test('reports nothing when every entry is fresh', () {
      final List<RemoteCacheEntry> entries = <RemoteCacheEntry>[
        _entry('jellyfin:a', now.add(const Duration(minutes: 2))),
        _entry('plex:b', now.add(const Duration(minutes: 5))),
      ];

      expect(cleanup.expiredKeys(entries, now), isEmpty);
    });
  });
}
