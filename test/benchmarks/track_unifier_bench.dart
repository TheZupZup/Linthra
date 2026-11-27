// A measurement harness, not a regression test.
//
// Times unifyTracks, which merges one song's copies from different servers,
// over libraries of several sizes held on two servers: once on the Dart rules
// and once in the Rust core, all marshalling included. It runs every time the
// library changes, over the whole catalog.
//
// Named `_bench.dart` so `flutter test` does not pick it up. Run it with:
//
//     flutter test test/benchmarks/track_unifier_bench.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/catalog/track_unifier.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// [songs] songs, each on Jellyfin and on Navidrome, the second copy's title
/// carrying a featured artist half the time. Names vary from their first
/// word, as a real library's do, so matching compares only plausible copies
/// (a catalog where every title began with the same word would put every song
/// in one block, which no library looks like).
List<Track> _library(int songs) => <Track>[
      for (int i = 0; i < songs; i++)
        for (final String scheme in <String>['jellyfin', 'subsonic'])
          Track(
            id: '$i',
            title: scheme == 'subsonic' && i.isEven
                ? 'T${i}x of the night (feat. Guest ${i % 50})'
                : 'T${i}x of the night',
            uri: '$scheme:$i',
            artistName: 'A${i % 900}z Band',
            albumName: 'L${i % 3000}q Record',
            duration: Duration(seconds: 120 + i % 300),
            trackNumber: 1 + i % 12,
          ),
    ];

int _ms(void Function() run) {
  final Stopwatch watch = Stopwatch()..start();
  run();
  return watch.elapsedMilliseconds;
}

void main() {
  test('unifyTracks in the Rust core', () {
    if (!LinthraCore.isAvailable) {
      markTestSkipped('Rust core not built');
      return;
    }
    const SourcePriority priority =
        SourcePriority(<String>['jellyfin', 'subsonic']);
    final StringBuffer report = StringBuffer('tracks       Rust (ms)\n');
    for (final int songs in <int>[5000, 25000, 100000]) {
      final List<Track> library = _library(songs);
      unifyTracks(library, priority); // warm up
      final int rust = _ms(() => unifyTracks(library, priority));
      expect(unifyTracks(library, priority).length, songs);
      report.writeln('${'${library.length}'.padLeft(7)}'
          '${'$rust'.padLeft(11)}');
    }
    // ignore: avoid_print
    print(report);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
