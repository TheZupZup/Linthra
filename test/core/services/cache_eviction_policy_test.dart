import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/cache_eviction_policy.dart';

/// A managed cache entry (has a file + size), the only kind eviction considers.
/// [source] is the provider scheme (`plex`/`jellyfin`/`subsonic`); when omitted
/// the entry has no source, exercising the legacy/source-less path.
CachedTrack _managed(
  String id, {
  String? source,
  int size = 100,
  DateTime? accessed,
  DateTime? cached,
  bool pinned = false,
  bool preloaded = false,
}) {
  return CachedTrack(
    trackId: id,
    sourceType: source,
    fileName: '${source ?? 'x'}_$id.mp3',
    sizeBytes: size,
    lastAccessedAt: accessed,
    cachedAt: cached,
    pinned: pinned,
    preloaded: preloaded,
  );
}

/// The provider-aware key the policy compares against, for a given `(source,
/// id)` — mirrors [CachedTrack.cacheKey].
String _key(String id, {String? source}) => CachedTrack.cacheKeyFor(source, id);

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
        protectKey: _key('playing'),
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
        protectKey: _key('playing'),
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

    test('evicts a preloaded track before any user download', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          // The user download is older, but a preload is sacrificed first.
          _managed('download', size: 100, accessed: DateTime(2024, 1, 1)),
          _managed('preload',
              size: 100, accessed: DateTime(2024, 6, 1), preloaded: true),
        ],
        incomingBytes: 100,
        maxBytes: 250,
      );

      expect(plan.fits, isTrue);
      expect(plan.evict.map((e) => e.trackId), <String>['preload']);
    });

    test('evicts older preloads first among several preloads', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('p-new',
              size: 100, cached: DateTime(2024, 6, 1), preloaded: true),
          _managed('p-old',
              size: 100, cached: DateTime(2024, 1, 1), preloaded: true),
          _managed('download', size: 100, accessed: DateTime(2024, 1, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 250, // need to free 2 of 3
      );

      // Both preloads go (oldest first) before the user download is touched.
      expect(plan.evict.map((e) => e.trackId), <String>['p-old', 'p-new']);
    });

    test('a re-download replaces its own copy rather than evicting others', () {
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('a', size: 100, accessed: DateTime(2024, 1, 1)),
          _managed('b', size: 100, accessed: DateTime(2024, 6, 1)),
        ],
        incomingBytes: 100,
        maxBytes: 200,
        incomingKey: _key('a'), // 'a' is being re-downloaded
      );

      // 'a' doesn't count as existing use, so b(100) + a(100) = 200 fits.
      expect(plan.fits, isTrue);
      expect(plan.evict, isEmpty);
    });

    group('provider isolation (same id across providers)', () {
      test('a re-download only skips its own provider, not a same-id other',
          () {
        // Plex 101 is being re-downloaded; a Subsonic 101 must NOT be mistaken
        // for its old copy — it still counts toward usage and stays evictable.
        final plan = policy.plan(
          cached: <CachedTrack>[
            _managed('101',
                source: 'plex', size: 100, accessed: DateTime(2024, 1, 1)),
            _managed('101',
                source: 'subsonic', size: 100, accessed: DateTime(2024, 2, 1)),
          ],
          incomingBytes: 100,
          // plex:101 replaces its own old copy (skipped); subsonic:101 (100)
          // plus the incoming (100) exceed 150, so subsonic:101 must give way.
          // Were it shadowed by the raw id, the policy would evict nothing.
          maxBytes: 150,
          incomingKey: _key('101', source: 'plex'),
        );

        expect(plan.fits, isTrue);
        // The same-id Subsonic track is evicted (it was NOT shadowed away).
        expect(plan.evict.length, 1);
        expect(plan.evict.single.sourceType, 'subsonic');
      });

      test('protecting the playing track protects only its provider', () {
        // Plex 101 is playing; a Jellyfin 101 with the same id is a different
        // track and must remain evictable.
        final plan = policy.plan(
          cached: <CachedTrack>[
            _managed('101',
                source: 'plex', size: 100, accessed: DateTime(2024, 1, 1)),
            _managed('101',
                source: 'jellyfin', size: 100, accessed: DateTime(2024, 2, 1)),
          ],
          incomingBytes: 100,
          maxBytes: 250, // must free one; the playing plex:101 is protected
          protectKey: _key('101', source: 'plex'),
        );

        expect(plan.fits, isTrue);
        expect(plan.evict.single.sourceType, 'jellyfin');
      });
    });

    test('evicts least-recently-used across providers, oldest first', () {
      // A mixed cache (Plex, Jellyfin, Subsonic) is ranked as one LRU list.
      final plan = policy.plan(
        cached: <CachedTrack>[
          _managed('p', source: 'plex', size: 100, accessed: DateTime(2024, 3)),
          _managed('j',
              source: 'jellyfin', size: 100, accessed: DateTime(2024, 1)),
          _managed('s',
              source: 'subsonic', size: 100, accessed: DateTime(2024, 2)),
        ],
        incomingBytes: 100,
        maxBytes: 300, // free exactly 1 of 3 → the least-recently-used 'j'
      );

      expect(plan.fits, isTrue);
      expect(plan.evict.single.trackId, 'j');
      expect(plan.evict.single.sourceType, 'jellyfin');
    });

    group('legacy records (written before sourceType existed)', () {
      test('protects a currently playing legacy entry by its bare id', () {
        // Upgrade case: the cached copy of the playing track is a legacy record
        // with no sourceType (key `\\0leg`), while the live playing track keys as
        // jellyfin:leg. It must still be protected — never evicted out from under
        // playback — even though its provider-aware key can't match.
        final plan = policy.plan(
          cached: <CachedTrack>[
            _managed('leg',
                accessed: DateTime(2024, 1, 1)), // legacy: no source
            _managed('other',
                source: 'jellyfin', accessed: DateTime(2024, 6, 1)),
          ],
          incomingBytes: 100,
          maxBytes: 250, // must free one
          protectKey: _key('leg', source: 'jellyfin'),
        );

        expect(plan.fits, isTrue);
        // The legacy playing entry is protected; the other track goes instead.
        expect(plan.evict.map((e) => e.trackId), <String>['other']);
      });

      test('a re-download recognizes its own legacy copy as its old copy', () {
        // Re-downloading jellyfin:leg whose existing copy is a legacy record:
        // it must be treated as the same track (skipped, replaced in place), not
        // a different evictable one.
        final plan = policy.plan(
          cached: <CachedTrack>[
            _managed('leg', accessed: DateTime(2024, 1, 1)), // legacy copy
            _managed('keep',
                source: 'jellyfin', accessed: DateTime(2024, 6, 1)),
          ],
          incomingBytes: 100,
          maxBytes:
              200, // leg replaces itself; keep(100)+incoming(100)=200 fits
          incomingKey: _key('leg', source: 'jellyfin'),
        );

        expect(plan.fits, isTrue);
        expect(plan.evict, isEmpty);
      });

      test('a legacy bare-id match never protects a same-id provider entry',
          () {
        // The playing track is jellyfin:101 (legacy copy `\\0101` exists). A
        // *different* provider's subsonic:101 carries a sourceType, so it is
        // matched strictly and stays evictable — the legacy fallback only ever
        // applies to source-less records.
        final plan = policy.plan(
          cached: <CachedTrack>[
            _managed('101',
                accessed: DateTime(2024, 1, 1)), // legacy, protected
            _managed('101', source: 'subsonic', accessed: DateTime(2024, 6, 1)),
          ],
          incomingBytes: 100,
          maxBytes: 250, // must free one
          protectKey: _key('101', source: 'jellyfin'),
        );

        expect(plan.fits, isTrue);
        // The provider-tagged Subsonic copy is evicted; the legacy one is kept.
        expect(plan.evict.single.sourceType, 'subsonic');
      });
    });
  });
}
