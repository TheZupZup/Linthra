// One tag field `audio_metadata_reader` can't parse makes it give up on the
// whole file (#776). What FLAC, OGG and Opus files still say in the clear has
// to survive that: their other tags, their length and their cover. And what a
// read of a file that stops answering halfway gives back has to be a failed
// read, never a partial one the scan would keep for good.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';

import 'audio_tag_fixtures.dart';

void main() {
  late FilesystemLocalMetadataReader reader;
  late Directory root;
  late Directory artworkDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linthra_odd_tags_');
    artworkDir = await Directory.systemTemp.createTemp('linthra_odd_art_');
    reader = FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(directory: () async => artworkDir),
    );
  });

  tearDown(() async {
    await reader.close();
    if (root.existsSync()) await root.delete(recursive: true);
    if (artworkDir.existsSync()) await artworkDir.delete(recursive: true);
  });

  String write(String name, Uint8List bytes) {
    final File file = File('${root.path}/$name');
    file.writeAsBytesSync(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List> solidPng(int size) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF993366),
    );
    final ui.Image image = await recorder.endRecording().toImage(size, size);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// Ogg Vorbis and Opus, the two containers that carry Vorbis comments in
  /// Ogg pages, each three seconds long.
  final Map<String, Uint8List Function(List<String> comments)> oggKinds =
      <String, Uint8List Function(List<String>)>{
    'song.ogg': (List<String> comments) =>
        AudioTagFixtures.oggVorbis(comments: comments),
    'song.opus': (List<String> comments) =>
        AudioTagFixtures.opus(comments: comments),
  };

  group('OGG and Opus files', () {
    for (final MapEntry<String, Uint8List Function(List<String>)> kind
        in oggKinds.entries) {
      test('${kind.key} gives its comments and a real duration', () async {
        final String path = write(
          kind.key,
          kind.value(<String>[
            'TITLE=Song',
            'ARTIST=Someone',
            'ALBUM=Record',
            'TRACKNUMBER=4',
          ]),
        );

        final LocalMetadataRead read = await reader.readWithOutcome(path);

        expect(read.failed, isFalse);
        expect(read.metadata!.title, 'Song');
        expect(read.metadata!.artist, 'Someone');
        expect(read.metadata!.album, 'Record');
        expect(read.metadata!.trackNumber, 4);
        expect(read.metadata!.duration, const Duration(seconds: 3));
      });
    }
  });

  group('an OGG or Opus the tag parser gives up on keeps what it says', () {
    for (final MapEntry<String, Uint8List Function(List<String>)> kind
        in oggKinds.entries) {
      test('${kind.key}: a vinyl track number keeps the other tags and length',
          () async {
        final String path = write(
          kind.key,
          kind.value(<String>[
            'TITLE=Side Opener',
            'ARTIST=The Band',
            'ALBUMARTIST=The Band',
            'ALBUM=On Vinyl',
            'TRACKNUMBER=A1',
          ]),
        );

        final LocalMetadataRead read = await reader.readWithOutcome(path);

        expect(read.failed, isFalse);
        expect(read.metadata!.title, 'Side Opener');
        expect(read.metadata!.artist, 'The Band');
        expect(read.metadata!.albumArtist, 'The Band');
        expect(read.metadata!.album, 'On Vinyl');
        expect(read.metadata!.trackNumber, isNull,
            reason: 'A1 and B1 are not both track 1');
        expect(read.metadata!.duration, const Duration(seconds: 3));
      });

      test('${kind.key}: an empty TRACKTOTAL keeps a 3/12 track number',
          () async {
        final String path = write(
          kind.key,
          kind.value(<String>['TITLE=Song', 'TRACKNUMBER=3/12', 'TRACKTOTAL=']),
        );

        final LocalMetadataRead read = await reader.readWithOutcome(path);

        expect(read.metadata!.title, 'Song');
        expect(read.metadata!.trackNumber, 3);
        expect(read.metadata!.duration, const Duration(seconds: 3));
      });

      test(
          '${kind.key}: no separator, a word for a number or a year, '
          'cost nothing', () async {
        for (final String odd in <String>[
          'NOSEPARATOR',
          'DISCTOTAL=two',
          'DISCNUMBER=one',
          'DATE=summer',
        ]) {
          final String path = write(
            kind.key,
            kind.value(<String>['TITLE=Song', 'ARTIST=Someone', odd]),
          );

          final LocalMetadataRead read = await reader.readWithOutcome(path);

          expect(read.failed, isFalse, reason: odd);
          expect(read.metadata?.title, 'Song', reason: odd);
          expect(read.metadata?.artist, 'Someone', reason: odd);
          expect(read.metadata?.duration, const Duration(seconds: 3),
              reason: odd);
        }
      });
    }

    test('a comment that is not UTF-8 costs only itself', () async {
      final String path = write(
        'latin1.opus',
        AudioTagFixtures.opus(
          comments: <String>['TITLE=Song', 'ARTIST=Someone'],
          // `COMMENT=Café` written in Latin-1 by an old tagger.
          rawComments: <List<int>>[
            <int>[...'COMMENT=Caf'.codeUnits, 0xE9],
          ],
        ),
      );

      final LocalMetadataRead read = await reader.readWithOutcome(path);

      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Song');
      expect(read.metadata!.artist, 'Someone');
    });

    test('its embedded cover is kept', () async {
      final String path = write(
        'cover.ogg',
        AudioTagFixtures.oggVorbis(
          comments: <String>['TITLE=Song', 'TRACKNUMBER=A1'],
          coverImage: await solidPng(32),
        ),
      );

      final LocalMetadataRead read = await reader.readWithOutcome(path);

      expect(read.metadata!.title, 'Song');
      expect(read.metadata!.artworkUri, isNotNull);
      expect(
          File(read.metadata!.artworkUri!.toFilePath()).existsSync(), isTrue);
    });

    test('comments running over several pages are read whole', () async {
      // Long lyrics push the comment header past one page's 255 segments.
      final String path = write(
        'long.opus',
        AudioTagFixtures.opus(comments: <String>[
          'LYRICS=${'la ' * 40000}',
          'TITLE=After The Lyrics',
          'TRACKNUMBER=A2',
        ]),
      );

      final LocalMetadataRead read = await reader.readWithOutcome(path);

      expect(read.metadata!.title, 'After The Lyrics');
      expect(read.metadata!.duration, const Duration(seconds: 3));
    });

    test('an Opus length counts 48 kHz granules, after the pre-skip', () async {
      // The source rate an Opus encoder was fed is informational only.
      final String path = write(
        'resampled.opus',
        AudioTagFixtures.opus(
          comments: <String>['TITLE=Song', 'TRACKNUMBER=A1'],
          inputSampleRate: 44100,
          preSkip: 3840,
          samples: 48000 * 2,
        ),
      );

      final LocalMetadataRead read = await reader.readWithOutcome(path);

      expect(read.metadata!.duration, const Duration(seconds: 2));
    });

    test(
        'an Ogg cut short keeps its tags, with no length rather than a wrong '
        'one', () async {
      final String path = write(
        'cut.ogg',
        AudioTagFixtures.oggVorbis(
          comments: <String>['TITLE=Song', 'TRACKNUMBER=A1'],
          lastPage: false,
        ),
      );

      final LocalMetadataRead read = await reader.readWithOutcome(path);

      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Song');
      expect(read.metadata!.duration, isNull);
    });
  });

  test('a FLAC the tag parser gives up on keeps its embedded cover', () async {
    final String path = write(
      'cover.flac',
      AudioTagFixtures.flac(
        title: 'Side Opener',
        track: 'A1',
        coverImage: await solidPng(32),
      ),
    );

    final LocalMetadataRead read = await reader.readWithOutcome(path);

    expect(read.metadata!.title, 'Side Opener');
    expect(read.metadata!.duration, const Duration(seconds: 3));
    expect(read.metadata!.artworkUri, isNotNull);
  });

  group('a file that stops answering halfway is a failed read', () {
    // The parse itself runs on an isolate of its own, which reads the real
    // file; what is read around it on this isolate goes through a file that
    // gives an I/O error on any read touching [failFrom, failTo).
    Future<(LocalMetadataRead, List<Symbol>)> readFailing(
      String path, {
      required int failFrom,
      int failTo = 1 << 40,
    }) async {
      final _FaultyFiles faults = _FaultyFiles(path, failFrom, failTo);
      final LocalMetadataRead read = await IOOverrides.runWithIOOverrides(
        () => reader.readWithOutcome(path),
        faults,
      );
      return (read, faults.unexpected);
    }

    Future<int> offsetOf(String path, List<int> marker) async {
      final Uint8List bytes = await File(path).readAsBytes();
      for (int i = 0; i + marker.length <= bytes.length; i++) {
        bool found = true;
        for (int j = 0; j < marker.length && found; j++) {
          found = bytes[i + j] == marker[j];
        }
        if (found) return i;
      }
      throw StateError('marker not found');
    }

    test('the harness itself reads a sound file through to its tags', () async {
      final String path = write(
          'sound.flac', AudioTagFixtures.flac(title: 'Song', track: 'A1'));

      final (LocalMetadataRead read, List<Symbol> unexpected) =
          await readFailing(path, failFrom: 1 << 30);

      expect(unexpected, isEmpty);
      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Song');
      expect(read.metadata!.duration, const Duration(seconds: 3));
    });

    test('a FLAC whose length can no longer be read is not kept without one',
        () async {
      final String path = write(
          'dying.flac', AudioTagFixtures.flac(title: 'Song', track: 'A1'));

      // STREAMINFO is the 34 bytes after `fLaC` and its 4-byte header.
      final (LocalMetadataRead read, List<Symbol> unexpected) =
          await readFailing(path, failFrom: 8, failTo: 8 + 34);

      expect(unexpected, isEmpty);
      expect(read.failed, isTrue);
      expect(read.metadata, isNull);
    });

    test('a FLAC whose cover can no longer be read is not kept without it',
        () async {
      final Uint8List cover = await solidPng(32);
      final String path = write(
        'dying-cover.flac',
        AudioTagFixtures.flac(title: 'Song', track: 'A1', coverImage: cover),
      );

      final (LocalMetadataRead read, List<Symbol> unexpected) =
          await readFailing(path, failFrom: await offsetOf(path, cover));

      expect(unexpected, isEmpty);
      expect(read.failed, isTrue);
    });

    test(
        'a FLAC the parser read whole, but whose artists then fail to read, '
        'is not kept with guessed ones', () async {
      final String path = write(
        'compilation.flac',
        AudioTagFixtures.flac(
          title: 'Song',
          artist: 'Featured Guest',
          albumArtist: 'Various Artists',
        ),
      );

      final (LocalMetadataRead read, List<Symbol> unexpected) =
          await readFailing(path,
              failFrom: await offsetOf(path, 'ARTIST'.codeUnits));

      expect(unexpected, isEmpty);
      expect(read.failed, isTrue);
    });

    test(
        'an Ogg whose last page can no longer be read is not kept without a '
        'length', () async {
      final Uint8List bytes = AudioTagFixtures.opus(
          comments: <String>['TITLE=Song', 'TRACKNUMBER=A1']);
      final String path = write('dying.opus', bytes);

      // The last page is the final 27 + 1 + 8 bytes.
      final (LocalMetadataRead read, List<Symbol> unexpected) =
          await readFailing(path, failFrom: bytes.length - 36);

      expect(unexpected, isEmpty);
      expect(read.failed, isTrue);
    });

    test('an Ogg whose cover can no longer be read is not kept without it',
        () async {
      final String path = write(
        'dying-cover.ogg',
        AudioTagFixtures.oggVorbis(
          comments: <String>['TITLE=Song', 'TRACKNUMBER=A1'],
          coverImage: await solidPng(32),
        ),
      );

      final (LocalMetadataRead read, List<Symbol> unexpected) =
          await readFailing(path,
              failFrom: await offsetOf(path, 'METADATA_BLOCK'.codeUnits));

      expect(unexpected, isEmpty);
      expect(read.failed, isTrue);
    });
  });
}

/// Gives the one file at [path] a handle whose reads fail with an I/O error
/// once they touch bytes [failFrom] to [failTo], the way a drive dying under
/// a scan answers. Everything else is the real file system.
final class _FaultyFiles extends IOOverrides {
  _FaultyFiles(this.path, this.failFrom, this.failTo);

  final String path;
  final int failFrom;
  final int failTo;

  /// Anything the reader asked the file or its handle for that this fake
  /// doesn't answer. A test asserts it stays empty, so a failed read is never
  /// the fake's own doing.
  final List<Symbol> unexpected = <Symbol>[];

  @override
  File createFile(String path) {
    final File real = super.createFile(path);
    return path == this.path ? _FaultyFile(real, this) : real;
  }
}

class _FaultyFile implements File {
  _FaultyFile(this._real, this._faults);

  final File _real;
  final _FaultyFiles _faults;

  @override
  String get path => _real.path;

  @override
  Future<FileStat> stat() => _real.stat();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _FaultyHandle(await _real.open(mode: mode), _faults);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _faults.unexpected.add(invocation.memberName);
    throw UnimplementedError('${invocation.memberName}');
  }
}

class _FaultyHandle implements RandomAccessFile {
  _FaultyHandle(this._real, this._faults);

  final RandomAccessFile _real;
  final _FaultyFiles _faults;

  @override
  String get path => _real.path;

  @override
  Future<Uint8List> read(int count) async {
    final int at = await _real.position();
    if (at < _faults.failTo && at + count > _faults.failFrom) {
      throw FileSystemException(
          'Input/output error', path, const OSError('I/O error', 5));
    }
    return _real.read(count);
  }

  @override
  Future<int> position() => _real.position();

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _real.setPosition(position);
    return this;
  }

  @override
  Future<int> length() => _real.length();

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _faults.unexpected.add(invocation.memberName);
    throw UnimplementedError('${invocation.memberName}');
  }
}
