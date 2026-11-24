// FilesystemLocalMetadataReader asks the Rust core first for FLAC, Ogg Vorbis
// and Opus. These tell its answer from the package's, so they show which path
// ran. Skipped in a build without the Rust core, where the package path is
// covered by the rest of this folder.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';

import 'audio_tag_fixtures.dart';

void main() {
  late Directory root;
  late Directory artworkDir;
  late FilesystemLocalMetadataReader reader;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linthra_native_tags_');
    artworkDir = await Directory.systemTemp.createTemp('linthra_native_art_');
    reader = FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(directory: () async => artworkDir),
    );
  });

  tearDown(() async {
    await reader.close();
    await root.delete(recursive: true);
    await artworkDir.delete(recursive: true);
  });

  Future<Uint8List> solidPng(int size) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF336699),
    );
    final ui.Image image = await recorder.endRecording().toImage(size, size);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  String write(String name, Uint8List bytes) =>
      (File('${root.path}/$name')..writeAsBytesSync(bytes, flush: true)).path;

  final Object skip =
      LinthraCore.isAvailable ? false : 'Rust core not built in this build';

  test('a blank first title gives way to the next one', skip: skip, () async {
    // The package keeps the first TITLE whatever it holds, and a blank one
    // then leaves the track named after its file.
    final String path = write(
      'blank_first.flac',
      AudioTagFixtures.flacWithRawComments(
          <String>['TITLE=  ', 'TITLE=Second', 'ARTIST=A']),
    );

    final LocalAudioMetadata? tags = await reader.readFromPath(path);

    expect(tags!.title, 'Second');
    expect(tags.artist, 'A');
    expect(tags.duration, const Duration(seconds: 3));
  });

  test('an Opus file comes back whole, cover included', skip: skip, () async {
    final String path = write(
      'song.opus',
      AudioTagFixtures.opus(
        comments: <String>['TITLE=Opus', 'ARTIST=A', 'ALBUMARTIST=B'],
        coverImage: await solidPng(8),
      ),
    );

    final LocalAudioMetadata? tags = await reader.readFromPath(path);

    expect(tags!.title, 'Opus');
    expect(tags.artist, 'A');
    expect(tags.albumArtist, 'B');
    expect(File(tags.artworkUri!.toFilePath()).existsSync(), isTrue);
  });

  test('an MP3 is left to the package', skip: skip, () async {
    final String path =
        write('song.mp3', AudioTagFixtures.mp3(title: 'Mp3', artist: 'A'));

    final LocalAudioMetadata? tags = await reader.readFromPath(path);

    expect(tags!.title, 'Mp3');
    expect(tags.artist, 'A');
  });
}
