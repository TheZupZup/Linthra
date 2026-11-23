// A measurement harness, not a regression test.
//
// Times one eviction plan on the Dart rules and on the Rust core, for caches
// of several sizes. The Rust time includes everything the app pays for: the
// metadata copied into native memory, the call, and the plan read back.
//
// Named `_bench.dart`, not `_test.dart`, so `flutter test` does not pick it
// up: the numbers depend on the machine and its load. That both paths give
// the same plan is covered by real tests (cache_eviction_cases_test.dart and
// cache_eviction_policy_test.dart). Run it explicitly:
//
//     flutter test test/benchmarks/cache_eviction_bench.dart
//
// `flutter test` runs Dart in JIT mode, so the Dart numbers are somewhat
// slower than a release build's. Compare the two paths on the same run.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/cache_eviction_policy.dart';

const List<int> _sizes = <int>[100, 1000, 10000, 50000];
const int _runs = 30;

/// A cache of [count] downloads, a fifth of them pre-cached and a tenth
/// pinned, played at scattered times, from three providers.
List<CachedTrack> _cache(int count) {
  final Random random = Random(count);
  const List<String> sources = <String>['jellyfin', 'subsonic', 'plex'];
  return <CachedTrack>[
    for (int i = 0; i < count; i++)
      CachedTrack(
        trackId: 'track-$i',
        sourceType: sources[i % 3],
        fileName: 'file_$i.flac',
        sizeBytes: 20000000 + random.nextInt(30000000),
        lastAccessedAt: random.nextInt(10) == 0
            ? null
            : DateTime.utc(2026).add(Duration(minutes: random.nextInt(500000))),
        cachedAt: DateTime.utc(2025).add(Duration(hours: i)),
        pinned: i % 10 == 0,
        preloaded: i % 5 == 0,
      ),
  ];
}

/// Median microseconds of [_runs] plans, after a warm-up.
int _time(CacheEvictionPolicy policy, List<CachedTrack> cached, int maxBytes) {
  EvictionPlan run() => policy.plan(
        cached: cached,
        incomingBytes: 40000000,
        maxBytes: maxBytes,
        protectKey: cached.first.cacheKey,
        protectKeys: <String>{
          for (final CachedTrack t in cached.take(3)) t.cacheKey
        },
      );
  for (int i = 0; i < 5; i++) {
    run();
  }
  final List<int> times = <int>[];
  for (int i = 0; i < _runs; i++) {
    final Stopwatch watch = Stopwatch()..start();
    run();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2];
}

void main() {
  test('cache eviction: Dart rules vs Rust core', () {
    if (!LinthraCore.isAvailable) {
      markTestSkipped('Rust core not built');
      return;
    }
    const CacheEvictionPolicy dart = CacheEvictionPolicy(useNative: false);
    const CacheEvictionPolicy rust = CacheEvictionPolicy();
    final StringBuffer report = StringBuffer()
      ..writeln('entries      Dart       Rust   (median of $_runs, µs)');
    for (final int count in _sizes) {
      final List<CachedTrack> cached = _cache(count);
      final int used =
          cached.fold(0, (int sum, CachedTrack t) => sum + t.sizeBytes);
      // A limit 10 % under what is cached: the plan has to sort every
      // candidate and evict a good share of them.
      final int maxBytes = used - used ~/ 10;
      expect(
        rust
            .plan(cached: cached, incomingBytes: 40000000, maxBytes: maxBytes)
            .evict,
        dart
            .plan(cached: cached, incomingBytes: 40000000, maxBytes: maxBytes)
            .evict,
      );
      report.writeln('${'$count'.padLeft(7)}'
          '${'${_time(dart, cached, maxBytes)}'.padLeft(10)}'
          '${'${_time(rust, cached, maxBytes)}'.padLeft(11)}');
    }
    // ignore: avoid_print
    print(report);
  });
}
