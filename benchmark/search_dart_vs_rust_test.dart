// Dart vs Rust library search on the same synthetic 200,000-track catalog.
//
// Not part of `flutter test` (which only runs test/). Run it on purpose, with
// Rust installed so the build hook bundles the native core:
//
//   flutter test benchmark/search_dart_vs_rust_test.dart
//
// What it compares, measured from Dart so the Rust numbers include the FFI
// call and copying the ids back:
//
// - Dart: filterTracks (lib/features/library/library_search.dart), the
//   Library search box today. No index; every query folds and scans every
//   track. Substring match, unranked, returns every match.
// - Rust: NativeSearchIndex. Builds an index once, then answers each query
//   from it. Word-prefix match, ranked, capped at `limit`.
//
// The two do not match the same things ("ica" finds "Metallica" in Dart, not
// in Rust), so the report also counts both result sets. A faster Rust answer
// is only a candidate replacement once the behaviour is agreed.
//
// Caveat: `flutter test` runs Dart on the JIT VM, not AOT as in a release
// app. The warm-up rounds let the JIT optimise first, which is close to AOT
// for a loop like this, but a phone running a release build is the number
// that finally counts.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/features/library/library_search.dart';

const int _trackCount = 200000;
const int _warmUpRounds = 3;
const int _measuredRounds = 15;

/// Realistic queries, including the short prefixes a search box sees while
/// someone is still typing, accents typed without the accent, and a miss.
const List<String> _queries = <String>[
  'm',
  'mid',
  'midnight',
  'midnight signal',
  'artist 421',
  'album 311 artist 731',
  'bjork',
  'beyonce',
  'track 199421',
  'zzzz',
];

/// Every tenth artist is a real-world accented name, so folding is exercised.
const List<String> _accented = <String>[
  'Björk',
  'Beyoncé',
  'Motörhead',
  'Sigur Rós',
  'Mötley Crüe',
  'Céline Dion',
  'Antonín Dvořák',
  'Françoise Hardy',
];

String _artist(int index) => index % 10 == 0
    ? _accented[(index ~/ 10) % _accented.length]
    : 'Artist ${index % 1500}';

String _provider(int index) =>
    const <String>['local', 'jellyfin', 'navidrome', 'plex'][index % 4];

List<Track> _dartLibrary() => List<Track>.generate(
      _trackCount,
      (int index) => Track(
        id: 'track-$index',
        uri: 'track-$index',
        title: 'Track $index Midnight Signal',
        artistName: _artist(index),
        albumName: 'Album ${index % 2500}',
        albumArtistName: _artist(index),
      ),
      growable: false,
    );

List<NativeSearchRecord> _rustLibrary() => List<NativeSearchRecord>.generate(
      _trackCount,
      (int index) => NativeSearchRecord(
        id: 'track-$index',
        title: 'Track $index Midnight Signal',
        artist: _artist(index),
        album: 'Album ${index % 2500}',
        albumArtist: _artist(index),
        provider: _provider(index),
      ),
      growable: false,
    );

/// Median wall time of [body] in microseconds, after [_warmUpRounds].
int _medianMicros(void Function() body) {
  for (int i = 0; i < _warmUpRounds; i++) {
    body();
  }
  final List<int> samples = <int>[];
  final Stopwatch watch = Stopwatch();
  for (int i = 0; i < _measuredRounds; i++) {
    watch
      ..reset()
      ..start();
    body();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(2).padLeft(9);

void main() {
  test(
    'Dart vs Rust search on $_trackCount tracks',
    () {
      if (!LinthraCore.isAvailable) {
        markTestSkipped('Rust core not built: install Rust and run again');
        return;
      }
      final List<Track> dartTracks = _dartLibrary();
      final List<NativeSearchRecord> rustRecords = _rustLibrary();

      final Stopwatch buildWatch = Stopwatch()..start();
      final NativeSearchIndex index = NativeSearchIndex.build(rustRecords)!;
      buildWatch.stop();
      addTearDown(index.dispose);

      final StringBuffer report = StringBuffer()
        ..writeln()
        ..writeln('Library search, $_trackCount tracks, median of '
            '$_measuredRounds runs after $_warmUpRounds warm-up')
        ..writeln('Rust index build (incl. passing every track over FFI): '
            '${_ms(buildWatch.elapsedMicroseconds).trim()} ms, once per '
            'catalog change')
        ..writeln()
        ..writeln('query                    Dart ms  Rust50 ms RustAll ms'
            '  x(50)  Dart hits  Rust hits')
        ..writeln('-' * 92);

      int dartTotal = 0;
      int rustTotal = 0;
      for (final String query in _queries) {
        int dartHits = 0;
        int rustHits = 0;
        final int dart = _medianMicros(() {
          dartHits = filterTracks(dartTracks, query).length;
        });
        final int rust50 = _medianMicros(() {
          index.search(query, limit: 50);
        });
        final int rustAll = _medianMicros(() {
          rustHits = index.search(query, limit: _trackCount).length;
        });
        dartTotal += dart;
        rustTotal += rust50;
        final String speedup =
            rust50 == 0 ? '   inf' : (dart / rust50).toStringAsFixed(0);
        report.writeln('${query.padRight(22)} ${_ms(dart)}  ${_ms(rust50)}  '
            '${_ms(rustAll)} ${speedup.padLeft(6)}x '
            '${'$dartHits'.padLeft(10)} ${'$rustHits'.padLeft(10)}');
      }

      final double perQuerySaved =
          (dartTotal - rustTotal) / _queries.length / 1000;
      report
        ..writeln('-' * 92)
        ..writeln('Dart ms: filterTracks, every match. Rust50: top 50 ranked, '
            'what the UI shows. RustAll: every match.')
        ..writeln('x(50): how many times faster Rust50 is than Dart.')
        ..writeln(perQuerySaved > 0
            ? 'The index build pays for itself after '
                '${(buildWatch.elapsedMicroseconds / 1000 / perQuerySaved).ceil()} '
                'searches (about ${perQuerySaved.toStringAsFixed(1)} ms saved '
                'per search).'
            : 'Rust saved no time per search on this machine.');
      stdout.write(report);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
