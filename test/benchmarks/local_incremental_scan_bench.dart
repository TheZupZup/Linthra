// A measurement harness, not a regression test.
//
// It answers the one question #411 exists for: on a library the size of a real
// one, how much of a rescan does the incremental path actually remove? The
// expensive part of a scan is opening each file and parsing its metadata
// blocks, so the harness gives the parser a deliberate, fixed cost per file and
// reports what a full scan pays versus what a rescan of an untouched library
// pays.
//
// Deliberately named `_bench.dart`, not `_test.dart`, so `flutter test` does
// not pick it up: the numbers are machine- and load-dependent and would make a
// flaky CI gate. The invariant it measures *is* covered by real tests, by
// counting parser calls rather than milliseconds
// (test/core/sources/local/local_incremental_scan_test.dart and
// test/features/library/incremental_library_scan_test.dart).
//
// Run it explicitly, and compare two revisions on the same machine:
//
//     flutter test test/benchmarks/local_incremental_scan_bench.dart
//
// The per-file parse cost is synthetic on purpose. A real tag read on a real
// disk is dominated by I/O that varies by an order of magnitude between an SSD
// and a spinning USB drive, and by page cache state; pinning it makes the
// comparison between the two scans mean something. `_parseCostMicros` is set
// to a conservative 200 microseconds, well under what a cold FLAC tag read
// costs in practice, so the reported saving is a floor rather than a boast.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';

/// Library sizes to report. 20k is a large personal collection; 100k is the
/// scale the large-library tooling targets.
const List<int> _librarySizes = <int>[2000, 20000, 100000];

/// What one tag read is charged, in microseconds of busy work. See the note at
/// the top of the file for why this is fixed rather than measured.
const int _parseCostMicros = 200;

/// A synthetic music tree: `<root>/Artist NN/Album NN/NN Title.flac`, so the
/// paths have the same depth and shape a real library's do.
class _SyntheticLibrary implements AudioFileScanner {
  _SyntheticLibrary(this.root, int count)
      : paths = List<String>.generate(count, (int i) {
          final int artist = i ~/ 200;
          final int album = (i ~/ 12) % 20;
          return '$root/Artist $artist/Album $album/${i % 12} Track $i.flac';
        }, growable: false);

  final String root;
  final List<String> paths;

  @override
  Future<List<String>> listFiles(String folder) async => paths;
}

/// Charges [_parseCostMicros] of real work per call, so "parsed" and "skipped"
/// differ by something a clock can see, without depending on a disk.
class _CostedMetadataReader implements LocalMetadataReader {
  int calls = 0;

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async {
    calls++;
    final Stopwatch spin = Stopwatch()..start();
    // Busy work rather than a sleep: a tag read is CPU and I/O, not an idle
    // wait, and an awaited delay would let the whole library "parse" in
    // parallel and measure nothing.
    int sink = 0;
    while (spin.elapsedMicroseconds < _parseCostMicros) {
      sink += utf8.encode(path).length;
    }
    return LocalAudioMetadata(
      title: 'Track $sink'.substring(0, 5),
      artist: 'Artist',
      album: 'Album',
      duration: const Duration(minutes: 3),
    );
  }
}

/// An in-memory stat: every file has a stamp, none of them change.
class _StaticStatReader implements LocalFileStatReader {
  _StaticStatReader(this.stamps);

  final Map<String, LocalFileStamp> stamps;
  int calls = 0;

  @override
  Future<LocalFileStamp?> stamp(String path) async {
    calls++;
    return stamps[path];
  }
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(1).padLeft(9);

void main() {
  for (final int size in _librarySizes) {
    test('incremental rescan of $size files', () async {
      const String root = '/music';
      final _SyntheticLibrary files = _SyntheticLibrary(root, size);
      final _StaticStatReader stats =
          _StaticStatReader(<String, LocalFileStamp>{
        for (int i = 0; i < files.paths.length; i++)
          files.paths[i]: LocalFileStamp(
            sizeBytes: 3000000 + i,
            modifiedAtMs: 1700000000000 + i,
          ),
      });

      final _CostedMetadataReader coldTags = _CostedMetadataReader();
      final Stopwatch cold = Stopwatch()..start();
      final LocalScan first = await LocalMusicSource(
        folderPath: root,
        scanner: files,
        metadataReader: coldTags,
        statReader: stats,
      ).scanTracks();
      cold.stop();

      final Map<String, StampedTrack> indexed = <String, StampedTrack>{
        for (final Track track in first.tracks)
          track.uri: StampedTrack(track: track, stamp: first.stamps[track.uri]),
      };

      final _CostedMetadataReader warmTags = _CostedMetadataReader();
      stats.calls = 0;
      final Stopwatch warm = Stopwatch()..start();
      final LocalScan second = await LocalMusicSource(
        folderPath: root,
        scanner: files,
        metadataReader: warmTags,
        statReader: stats,
        alreadyIndexed: indexed,
      ).scanTracks();
      warm.stop();

      // The result has to be identical, or the saving is not a saving.
      expect(second.tracks, hasLength(size));
      expect(warmTags.calls, 0);
      expect(second.report.reusedTracks, size);

      final double factor = warm.elapsedMicroseconds == 0
          ? double.infinity
          : cold.elapsedMicroseconds / warm.elapsedMicroseconds;
      // ignore: avoid_print
      print(
        'files ${size.toString().padLeft(7)}   '
        'full ${_ms(cold.elapsedMicroseconds)} ms   '
        'rescan ${_ms(warm.elapsedMicroseconds)} ms   '
        'parsed ${coldTags.calls} -> ${warmTags.calls}   '
        'stats ${stats.calls}   '
        '${factor.toStringAsFixed(1)}x faster',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
