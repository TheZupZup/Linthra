// A measurement harness, not a regression test.
//
// Times sorting the Albums grid in every order but the grouped one, which is
// returned as it is, to check that it does not need the Rust core.
//
// Named `_bench.dart` so `flutter test` does not pick it up. Run it with:
//
//     flutter test test/benchmarks/album_sort_bench.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/features/library/album_sort.dart';

void main() {
  test('sortAlbums on 20 000 albums', () {
    const int size = 20000;
    final List<Album> albums = <Album>[
      for (int i = 0; i < size; i++)
        Album(
          id: 'album-$i',
          title: 'Álbum ${(i * 7919) % size}',
          artistName: i % 50 == 0 ? null : 'Artist ${i % 900}',
        ),
    ];
    final Map<String, DateTime> addedAt = <String, DateTime>{
      for (int i = 0; i < size; i++)
        if (i % 20 != 0)
          'album-$i': DateTime.utc(2020).add(Duration(hours: (i * 31) % size)),
    };
    final StringBuffer report = StringBuffer('sortAlbums, $size albums\n');
    for (final AlbumSort sort in AlbumSort.values) {
      if (sort == AlbumSort.titleAscending) continue;
      // A warm-up, then the best of five.
      sortAlbums(albums, sort, addedAt: addedAt);
      int best = 1 << 30;
      for (int run = 0; run < 5; run++) {
        final Stopwatch watch = Stopwatch()..start();
        sortAlbums(albums, sort, addedAt: addedAt);
        if (watch.elapsedMilliseconds < best) best = watch.elapsedMilliseconds;
      }
      report.writeln('  ${sort.name}: $best ms');
    }
    // ignore: avoid_print
    print(report);
  });
}
