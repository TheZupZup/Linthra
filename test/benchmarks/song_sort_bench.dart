// A measurement harness, not a regression test.
//
// Times sorting the Songs list as the Library does it, the album index
// included (SongAlbums.of, then sortSongs against it), in the Rust core with
// all marshalling. It runs on every change of order
// and every reload of the library.
//
// Named `_bench.dart` so `flutter test` does not pick it up. Run it with:
//
//     flutter test test/benchmarks/song_sort_bench.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/song_sort.dart';

List<Track> _library(int size) => <Track>[
      for (int i = 0; i < size; i++)
        Track(
          id: '$i',
          title: 'T${(i * 7919) % size} Song',
          uri: 'jellyfin:$i',
          artistName: 'Artist ${i % 900}',
          albumName: 'Album ${i % 3000}',
          albumId: 'album-${i % 3000}',
          trackNumber: 1 + i % 12,
        ),
    ];

int _ms(void Function() run) {
  final Stopwatch watch = Stopwatch()..start();
  run();
  return watch.elapsedMilliseconds;
}

void main() {
  test('sortSongs in the Rust core', () {
    final StringBuffer report =
        StringBuffer('songs     order           Rust (ms)\n');
    for (final int size in <int>[20000, 200000]) {
      final List<Track> library = _library(size);
      for (final SongSort sort in <SongSort>[
        SongSort.titleAscending,
        SongSort.artistAscending,
        SongSort.albumAscending,
      ]) {
        void run() => sortSongs(library, sort, albums: SongAlbums.of(library));
        run();
        final int rust = _ms(run);
        report.writeln('${'$size'.padLeft(6)}  ${sort.name.padRight(16)}'
            '${'$rust'.padLeft(6)}');
      }
    }
    // ignore: avoid_print
    print(report);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
