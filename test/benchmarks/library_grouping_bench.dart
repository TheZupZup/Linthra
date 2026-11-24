// A measurement harness, not a regression test.
//
// Times the Library's album and artist grouping on the Dart rules and on the
// Rust core, for catalogs of several sizes. The Rust time includes everything
// the app pays for: lower-casing, copying the names into native memory, the
// call, and building the Album and Artist models from the answer.
//
// Named `_bench.dart`, not `_test.dart`, so `flutter test` does not pick it
// up: the numbers depend on the machine and its load. That both paths give
// the same albums and artists is covered by
// test/core/catalog/library_grouping_native_test.dart. Run it explicitly:
//
//     flutter test test/benchmarks/library_grouping_bench.dart
//
// `flutter test` runs Dart in JIT mode, so the Dart numbers are somewhat
// slower than a release build's. Compare the two paths on the same run.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';

const List<int> _sizes = <int>[100, 1000, 10000, 50000, 200000];
const int _runs = 10;

/// [count] tracks over about count / 12 albums by count / 50 artists, with
/// accents, a third of them carrying a server album id.
List<Track> _catalog(int count) => <Track>[
      for (int i = 0; i < count; i++)
        Track(
          id: 'track-$i',
          title: 'Sông $i',
          uri: 'file:///music/$i.flac',
          artistName: 'Ärtist ${i % (count ~/ 50 + 1)}',
          albumName: 'Álbum ${i % (count ~/ 12 + 1)}',
          albumId: i % 3 == 0 ? 'jellyfin:al-${i % (count ~/ 12 + 1)}' : null,
          albumArtistName: i % 7 == 0 ? 'Various Ärtists' : null,
          trackNumber: i % 12 + 1,
        ),
    ];

/// Median microseconds of [_runs] runs of [run], after a warm-up.
int _time(void Function() run) {
  for (int i = 0; i < 3; i++) {
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
  test('library grouping: Dart vs Rust', () {
    if (!LinthraCore.isAvailable) {
      markTestSkipped('Rust core not built');
      return;
    }
    final StringBuffer out = StringBuffer()
      ..writeln('albums + artists, median of $_runs')
      ..writeln('  tracks        Dart        Rust');
    for (final int size in _sizes) {
      final List<Track> tracks = _catalog(size);
      final int dart = _time(() {
        groupAlbumsInDart(tracks);
        groupArtistsInDart(tracks);
      });
      final int rust = _time(() => groupLibrary(tracks));
      out.writeln(
        '${size.toString().padLeft(8)}  ${_ms(dart).padLeft(10)}  '
        '${_ms(rust).padLeft(10)}',
      );
    }
    // ignore: avoid_print
    print(out);
  });
}
