import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/cache_eviction_policy.dart';

/// A managed cache entry (has a file + size), the only kind eviction considers.
CachedTrack _managed(
  String id, {
  int size = 100,
  DateTime? accessed,
  DateTime? cached,
  bool pinned = false,
}) {
  return CachedTrack(
    trackId: id,
    fileName: '$id.mp3',
    sizeBytes: size,
    lastAccessedAt: accessed,
    cachedAt: cached,
    pinned: pinned,
  );
}

void main() {
  const CacheEvictionPolicy policy = CacheEvictionPolicy();

  group('CacheEvictionPolicy', () {
    test('fits with no eviction when there is room', () {
      final plan = policy.plan(
        cached: <CachedTrack>[_managed('a', size: 100)],
        incomingBytes: 100,
        maxBytes: 1000,
      );

      expect(plan.fits, isTrue);
      expect(plan.evict, isEmpty);
    });

    test('evicts the least-recently-used track first', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('old', size: 100, accessed: DateTime(2024, 1, 1)),
          _managed('new', size: 100, accessed: DateTime(2024, 6, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 250, // room for two 100s; a third needs one evicted
      );

      expect(plan.fits, isTrue);
      expect(plan.evict.map((e) => e.trackId), <String>['old']);
    });

    test('a never-played track is treated as oldest', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('played', size: 100, accessed: DateTime(2024, 1, 1)),
          _managed('never', size: 100), // no lastAccessedAt
        ],
        incomingBytes: 100,
        maxBytes: 250,
      );

      expect(plan.evict.map((e) => e.trackId), <String>['never']);
    });

    test('evicts several, least-recently-used first, until it fits', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('a', size: 100, accessed: DateTime(2024, 1, 1)),
          _managed('b', size: 100, accessed: DateTime(2024, 2, 1)),
          _managed('c', size: 100, accessed: DateTime(2024, 3, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 250, // used 300 + 100 = 400; must free to <= 250 → drop 2
      );

      expect(plan.fits, isTrue);
      expect(plan.evict.map((e) => e.trackId), <String>['a', 'b']);
    });

    test('never evicts a pinned track', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('pinned',
              size: 100, accessed: DateTime(2024, 1, 1), pinned: true),
          _managed('loose', size: 100, accessed: DateTime(2024, 6, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 250,
      );

      expect(plan.fits, isTrue);
      expect(plan.evict.map((e) => e.trackId), <String>['loose']);
    });

    test('never evicts the currently playing track', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('playing', size: 100, accessed: DateTime(2024, 1, 1)),
          _managed('other', size: 100, accessed: DateTime(2024, 6, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 250,
        protectTrackId: 'playing',
      );

      expect(plan.fits, isTrue);
      expect(plan.evict.map((e) => e.trackId), <String>['other']);
    });

    test('does not fit when only pinned/playing tracks remain', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('pinned', size: 100, pinned: true),
          _managed('playing', size: 100),
        ],
        incomingBytes: 100,
        maxBytes: 250, // used 200 + 100 = 300 > 250, nothing safe to drop
        protectTrackId: 'playing',
      );

      expect(plan.fits, isFalse);
      // Nothing is evicted when it still wouldn't fit.
      expect(plan.evict, isEmpty);
    });

    test('a track larger than the whole limit never fits and evicts nothing',
        () {
      final plan = policy.plan(
        cached: <CachedTrack>[_managed('a', size: 100)],
        incomingBytes: 5000,
        maxBytes: 1000,
      );

      expect(plan.fits, isFalse);
      expect(plan.evict, isEmpty);
    });

    test('on-device entries do not count and are never evicted', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          const CachedTrack(trackId: 'local'), // no file, size 0
          _managed('remote', size: 100, accessed: DateTime(2024, 1, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 150,
      );

      // Only the managed remote track counts (100) and is the sole candidate.
      expect(plan.fits, isTrue);
      expect(plan.evict.map((e) => e.trackId), <String>['remote']);
    });

    test('a re-download replaces its own copy rather than evicting others', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('a', size: 100, accessed: DateTime(2024, 1, 1)),
          _managed('b', size: 100, accessed: DateTime(2024, 6, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 200,
        incomingTrackId: 'a', // 'a' is being re-downloaded
      );

      // 'a' doesn't count as existing use, so b(100) + a(100) = 200 fits.
      expect(plan.fits, isTrue);
      expect(plan.evict, isEmpty);
    });
  });
}
