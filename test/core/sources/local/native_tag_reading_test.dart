// FilesystemLocalMetadataReader asks the Rust core first for FLAC, Ogg Vorbis,
// Opus, MP3, MP4, WAV, AIFF and Monkey's Audio. These tell its answer from
// the package's, so they show which path ran.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';

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

  test('a blank first title gives way to the next one', () async {
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

  test('an Opus file comes back whole, cover included', () async {
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

  test('an MP3 is read by the Rust core too', () async {
    final String path =
        write('song.mp3', AudioTagFixtures.mp3(title: 'Mp3', artist: 'A'));

    final LocalAudioMetadata? tags = await reader.readFromPath(path);

    expect(tags!.title, 'Mp3');
    expect(tags.artist, 'A');
    expect(tags.duration, isNotNull);
  });

  group('#855: odd text in an MP3 tag no longer drops the file', () {
    test('a UTF-8 frame holding Latin-1 bytes', () async {
      final LocalMetadataRead read = await reader
          .readWithOutcome('test/fixtures/tags/id3v24_invalid_utf8.mp3');

      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Caf\u00e9');
      expect(read.metadata!.albumArtist, 'Caf\u00e9 Society');
      expect(read.metadata!.duration, isNotNull);
    });

    test('only an ID3v1 tag, Latin-1 and NUL-padded', () async {
      final LocalMetadataRead read =
          await reader.readWithOutcome('test/fixtures/tags/id3v1_only.mp3');

      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Caf\u00e9');
      expect(read.metadata!.artist, 'Old Rip');
      expect(read.metadata!.trackNumber, 7);
    });
  });

  group('MP4', () {
    test('an unfinished encode keeps its tags', () async {
      // Its `mdat` is still sized 0, the box the package looped on; the MP4
      // guard refuses it on the Dart path.
      final LocalMetadataRead read = await reader
          .readWithOutcome('test/fixtures/tags/m4a_mdat_size_zero.m4a');

      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Unfinished');
    });

    test('#855: a CDDB track number of A1 no longer drops the file', () async {
      final LocalMetadataRead read =
          await reader.readWithOutcome('test/fixtures/tags/m4a_cddb_vinyl.m4a');

      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Vinyl');
      expect(read.metadata!.trackNumber, isNull);
    });

    test('the album artist is read', () async {
      final LocalAudioMetadata? tags =
          await reader.readFromPath('test/fixtures/tags/m4a_basic.m4a');

      expect(tags!.albumArtist, 'Various Artists');
      expect(tags.trackNumber, 3);
      expect(tags.duration, const Duration(seconds: 3));
    });
  });

  group('WAV, AIFF and APE', () {
    test("a WAV's id3 chunk wins over its INFO list", () async {
      final LocalAudioMetadata? tags =
          await reader.readFromPath('test/fixtures/tags/wav_id3.wav');

      expect(tags!.title, 'From ID3');
      expect(tags.artist, 'Info Artist');
      expect(tags.albumArtist, 'AA');
      expect(tags.duration, const Duration(seconds: 1));
    });

    test('an AIFF has its length from its 80-bit sample rate', () async {
      final LocalAudioMetadata? tags =
          await reader.readFromPath('test/fixtures/tags/aiff_22050.aiff');

      expect(tags!.title, 'Half rate');
      expect(tags.duration, const Duration(milliseconds: 1500));
    });

    test('an MP3 with only an APE tag keeps it', () async {
      final LocalAudioMetadata? tags =
          await reader.readFromPath('test/fixtures/tags/mp3_with_ape.mp3');

      expect(tags!.title, 'Ape Title');
      expect(tags.albumArtist, 'Ape AA');
      expect(tags.trackNumber, 5);
    });

    test("a Monkey's Audio file has a length", () async {
      final LocalMetadataRead read =
          await reader.readWithOutcome('test/fixtures/tags/monkeys_new.ape');

      expect(read.metadata!.title, 'Monkey');
      expect(read.metadata!.duration, const Duration(microseconds: 7687346));
    });
  });
}
