import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/vorbis_tags_in_the_clear.dart';

import 'audio_tag_fixtures.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linthra_in_the_clear_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  File write(String name, List<int> bytes) =>
      File('${root.path}/$name')..writeAsBytesSync(bytes, flush: true);

  /// A tiny stand-in "image": the reader hands the bytes on without decoding
  /// them.
  final Uint8List cover = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

  test('anything but a FLAC or an Ogg Vorbis or Opus stream is not guessed at',
      () async {
    for (final (String name, Uint8List bytes) in <(String, Uint8List)>[
      ('song.mp3', AudioTagFixtures.mp3(title: 'X')),
      ('song.wav', AudioTagFixtures.wav(title: 'X')),
      ('song.m4a', AudioTagFixtures.m4a(title: 'X')),
      ('empty.ogg', Uint8List(0)),
    ]) {
      expect(
        await VorbisTagsInTheClear.read(write(name, bytes), withCover: true),
        isNull,
        reason: name,
      );
    }
  });

  test('an Ogg stream of another codec is not guessed at', () async {
    final Uint8List bytes =
        AudioTagFixtures.opus(comments: <String>['TITLE=X']);
    // `OpusHead` on the first page becomes `OpusHeaX`: no codec this reads.
    bytes[28 + 7] = 0x58;

    expect(
      await VorbisTagsInTheClear.read(write('other.ogg', bytes),
          withCover: false),
      isNull,
    );
  });

  test('a file gone by the time it is read throws, as an I/O error does',
      () async {
    await expectLater(
      VorbisTagsInTheClear.read(File('${root.path}/gone.ogg'),
          withCover: false),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('the cover is only looked for when asked for', () async {
    for (final (String name, Uint8List bytes) in <(String, Uint8List)>[
      ('song.flac', AudioTagFixtures.flac(title: 'X', coverImage: cover)),
      (
        'song.ogg',
        AudioTagFixtures.oggVorbis(
            comments: <String>['TITLE=X'], coverImage: cover)
      ),
    ]) {
      final File file = write(name, bytes);

      final VorbisTagsInTheClear? withCover =
          await VorbisTagsInTheClear.read(file, withCover: true);
      final VorbisTagsInTheClear? without =
          await VorbisTagsInTheClear.read(file, withCover: false);

      expect(withCover!.cover, cover, reason: name);
      expect(without!.cover, isNull, reason: name);
      expect(without.fields['TITLE'], <String>['X'], reason: name);
    }
  });

  test('`OggS` turning up after the last page is not taken for one', () async {
    // Trailing bytes that look like a page header, as a stray `OggS` in junk
    // appended to a file would, but whose checksum doesn't hold.
    final List<int> junk = <int>[
      ...'OggS'.codeUnits,
      0, 4, // version, end of stream
      0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, // granule: a very long stream
      0x54, 0x4E, 0x49, 0x4C, // the fixture's serial
      9, 0, 0, 0,
      0, 0, 0, 0, // no valid checksum
      0, // no segments
    ];
    final File file = write('trailing.opus', <int>[
      ...AudioTagFixtures.opus(comments: <String>['TITLE=X']),
      ...junk,
    ]);

    final VorbisTagsInTheClear? read =
        await VorbisTagsInTheClear.read(file, withCover: false);

    expect(read!.duration, const Duration(seconds: 3));
  });

  test('a page of another stream at the end is skipped for the length',
      () async {
    // The fixture's audio page, copied under another serial and a granule
    // far beyond, then given a checksum that holds for it.
    final Uint8List opus = AudioTagFixtures.opus(comments: <String>['TITLE=X']);
    final Uint8List foreign =
        Uint8List.fromList(opus.sublist(opus.length - 36));
    final ByteData view = ByteData.sublistView(foreign);
    view.setInt64(6, 48000 * 600, Endian.little);
    view.setUint32(14, 0x12345678, Endian.little);
    view.setUint32(22, 0, Endian.little);
    view.setUint32(22, _oggCrc(foreign), Endian.little);

    final VorbisTagsInTheClear? read = await VorbisTagsInTheClear.read(
        write('multiplexed.opus', <int>[...opus, ...foreign]),
        withCover: false);

    expect(read!.duration, const Duration(seconds: 3));
  });
}

int _oggCrc(List<int> bytes) {
  int crc = 0;
  for (final int byte in bytes) {
    crc ^= byte << 24;
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : crc << 1;
      crc &= 0xFFFFFFFF;
    }
  }
  return crc;
}
