// A measurement harness, not a regression test.
//
// Times the end-of-scan reconciliation (which local files moved, which are
// gone) on the Dart rules and on the Rust core. The Rust time includes
// everything the app pays for: asking which folders were read, lower-casing,
// copying the tags into native memory, the call, and building the moves.
//
// Named `_bench.dart`, not `_test.dart`, so `flutter test` does not pick it
// up: the numbers depend on the machine and its load. That both paths agree
// is covered by
// test/core/sources/local/local_catalog_reconciliation_native_test.dart.
// Run it explicitly:
//
//     flutter test test/benchmarks/local_reconcile_bench.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';

const List<int> _sizes = <int>[1000, 10000, 50000, 200000];
const int _runs = 5;

Track _track(String folder, int i) => Track(
      id: '/$folder/$i.flac',
      title: 'Sông $i',
      uri: '/$folder/$i.flac',
      artistName: 'Ärtist ${i % 400}',
      albumName: 'Álbum ${i ~/ 12}',
      duration: Duration(seconds: 180 + i % 120),
      trackNumber: i % 12 + 1,
    );

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
  test('local reconciliation: Dart vs Rust', () {
    if (!LinthraCore.isAvailable) {
      markTestSkipped('Rust core not built');
      return;
    }
    final StringBuffer out = StringBuffer()
      ..writeln('a tenth of the library moved, median of $_runs')
      ..writeln('  tracks        Dart        Rust');
    for (final int size in _sizes) {
      final List<Track> previous = <Track>[
        for (int i = 0; i < size; i++) _track('music', i),
      ];
      final List<Track> scanned = <Track>[
        for (int i = 0; i < size; i++)
          _track(i % 10 == 0 ? 'moved' : 'music', i),
      ];
      bool refreshed(String uri) => true;
      final int dart = _time(() => LocalCatalogReconciliation.resolveInDart(
          previous: previous, scanned: scanned, wasRefreshed: refreshed));
      final int rust = _time(() => LocalCatalogReconciliation.resolve(
          previous: previous, scanned: scanned, wasRefreshed: refreshed));
      out.writeln(
        '${size.toString().padLeft(8)}  ${_ms(dart).padLeft(10)}  '
        '${_ms(rust).padLeft(10)}',
      );
    }
    // ignore: avoid_print
    print(out);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
