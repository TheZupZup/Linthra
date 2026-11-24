// A measurement harness, not a regression test.
//
// Times FilesystemLocalMetadataReader over a folder of FLAC, Ogg Vorbis, Opus
// and MP3 files with covers, as a first scan reads them: once with the Rust
// core reading the tags, once with the Dart path (the package, then a second
// read for the FLAC artists). Each run gets an empty artwork cache, so every
// cover is extracted and stored.
//
// Named `_bench.dart` so `flutter test` does not pick it up. Run it with:
//
//     flutter test test/benchmarks/local_tag_read_bench.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';

import '../core/sources/local/audio_tag_fixtures.dart';

const int _filesPerFormat = 400;

/// Milliseconds to read every file in [paths], with a fresh artwork cache.
Future<int> _scan(List<String> paths, {required bool useNativeTags}) async {
  final Directory art = await Directory.systemTemp.createTemp('linthra_art_');
  final FilesystemLocalMetadataReader reader = FilesystemLocalMetadataReader(
    artworkCache: LocalArtworkCache(directory: () async => art),
    useNativeTags: useNativeTags,
  );
  try {
    // Warm the parser isolate, which a real scan starts once.
    await reader.readWithOutcome(paths.first);
    final Stopwatch watch = Stopwatch()..start();
    for (final String path in paths) {
      final LocalMetadataRead read = await reader.readWithOutcome(path);
      if (read.failed || read.metadata?.title == null) {
        throw StateError('a fixture did not read');
      }
    }
    return watch.elapsedMilliseconds;
  } finally {
    await reader.close();
    await art.delete(recursive: true);
  }
}

void main() {
  test('local tag reading: Dart path vs Rust core', () async {
    if (!LinthraCore.isAvailable) {
      markTestSkipped('Rust core not built');
      return;
    }
    final Directory root =
        await Directory.systemTemp.createTemp('linthra_tag_bench_');
    try {
      // A cover of 60 KB, about what a 600×600 JPEG weighs. Not a real
      // image, so the artwork cache turns it down after a failed decode:
      // what is timed is the reading, which is what differs.
      final Uint8List cover =
          Uint8List.fromList(List<int>.generate(60000, (int i) => i % 251));
      final List<String> paths = <String>[];
      for (int i = 0; i < _filesPerFormat; i++) {
        for (final (String name, Uint8List bytes) in <(String, Uint8List)>[
          (
            'track_$i.flac',
            AudioTagFixtures.flac(
              title: 'Song $i',
              artist: 'Artist ${i % 40}',
              albumArtist: 'Album Artist ${i % 20}',
              album: 'Album ${i % 30}',
              track: '${i % 12 + 1}/12',
              coverImage: cover,
            ),
          ),
          (
            'track_$i.ogg',
            AudioTagFixtures.oggVorbis(
              comments: <String>['TITLE=Song $i', 'ARTIST=Artist ${i % 40}'],
              coverImage: cover,
            ),
          ),
          (
            'track_$i.mp3',
            AudioTagFixtures.mp3(
              title: 'Song $i',
              artist: 'Artist ${i % 40}',
              albumArtist: 'Album Artist ${i % 20}',
              album: 'Album ${i % 30}',
              track: '${i % 12 + 1}/12',
              coverImage: cover,
            ),
          ),
          (
            'track_$i.opus',
            AudioTagFixtures.opus(
              comments: <String>['TITLE=Song $i', 'ARTIST=Artist ${i % 40}'],
              coverImage: cover,
            ),
          ),
        ]) {
          final File file = File('${root.path}/$name')..writeAsBytesSync(bytes);
          paths.add(file.path);
        }
      }

      final int dart = await _scan(paths, useNativeTags: false);
      final int rust = await _scan(paths, useNativeTags: true);
      // ignore: avoid_print
      print('${paths.length} files with covers: '
          'Dart path $dart ms, Rust core $rust ms');
    } finally {
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
