// A measurement harness, not a regression test.
//
// Times the cross-provider merge (unifyTracks) on the Dart rules and on the
// Rust core, for catalogs of several sizes. The Rust time includes everything
// the app pays for: working out each track's provider, lower-casing, copying
// the fields into native memory, the call, and building the LogicalTracks.
//
// Named `_bench.dart`, not `_test.dart`, so `flutter test` does not pick it
// up: the numbers depend on the machine and its load. That both paths give
// the same logical tracks is covered by
// test/core/catalog/track_unifier_native_test.dart. Run it explicitly:
//
//     flutter test test/benchmarks/track_unifier_bench.dart
//
// `flutter test` runs Dart in JIT mode, so the Dart numbers are somewhat
// slower than a release build's. Compare the two paths on the same run.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/catalog/track_unifier.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';

const List<int> _sizes = <int>[1000, 10000, 50000, 200000];
const int _runs = 5;

/// [count] tracks, half served by Jellyfin and half by Navidrome, the same
/// library tagged slightly differently on each side, so every song merges.
/// Artists and titles start with distinct words, as real ones mostly do, so
/// blocks stay small.
List<Track> _catalog(int count) => <Track>[
      for (int i = 0; i < count; i++)
        Track(
          id: '${i ~/ 2}',
          title: i.isEven ? 'Sông${i ~/ 2} Ẽ' : 'Sông${i ~/ 2} Ẽ (feat. Guest)',
          uri: '${i.isEven ? 'jellyfin' : 'subsonic'}:${i ~/ 2}',
          artistName: 'Ärtist${i ~/ 2 % (count ~/ 50 + 1)}',
          albumName:
              i.isEven ? 'Álbum ${i ~/ 24}' : 'Álbum ${i ~/ 24} (Deluxe)',
          duration: Duration(seconds: 180 + i % 2),
          trackNumber: i ~/ 2 % 12 + 1,
        ),
    ];

/// Median microseconds of [_runs] runs of [run], after a warm-up.
int _time(void Function() run) {
  for (int i = 0; i < 2; i++) {
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

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(1)} ms';

void main() {
  test('track unifier: Dart vs Rust', () {
    if (!LinthraCore.isAvailable) {
      markTestSkipped('Rust core not built');
      return;
    }
    final StringBuffer out = StringBuffer()
      ..writeln('unifyTracks, median of $_runs')
      ..writeln('  tracks        Dart        Rust');
    for (final int size in _sizes) {
      final List<Track> tracks = _catalog(size);
      final int dart =
          _time(() => unifyTracksInDart(tracks, SourcePriority.fallback));
      final int rust =
          _time(() => unifyTracks(tracks, SourcePriority.fallback));
      out.writeln(
        '${size.toString().padLeft(8)}  ${_ms(dart).padLeft(10)}  '
        '${_ms(rust).padLeft(10)}',
      );
    }
    // ignore: avoid_print
    print(out);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
