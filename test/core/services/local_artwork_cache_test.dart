import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';

/// A real, decodable solid-colour PNG of [width]x[height] — a corrupt/garbage
/// byte string can stand in for "not an image", but bounding/resizing needs a
/// container [LocalArtworkCache]'s decoder can actually walk.
Future<Uint8List> _solidPng(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFAA5533),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Size> _decodedSize(Uint8List bytes) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    bytes,
  );
  final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
    buffer,
  );
  final ui.Size size =
      ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  descriptor.dispose();
  buffer.dispose();
  return size;
}

/// What a file looked like on disk when its cover was extracted. The cache
/// never stats anything itself — the reader hands it the stamp — so a test can
/// describe a re-tag simply by passing a different one.
LocalFileStamp _stamp({int size = 4096, int mtime = 1700000000000}) =>
    LocalFileStamp(sizeBytes: size, modifiedAtMs: mtime);

void main() {
  late Directory dir;
  late LocalArtworkCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_artwork_cache_test');
    cache = LocalArtworkCache(directory: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('a fresh path has no cached file', () async {
    expect(await cache.cachedFile('/music/song.flac', _stamp()), isNull);
  });

  test('store writes the image and cachedFile then finds it', () async {
    final Uint8List cover = await _solidPng(32, 32);

    final Uri? uri = await cache.store('/music/song.flac', _stamp(), cover);

    expect(uri, isNotNull);
    expect(uri!.isScheme('file'), isTrue);
    final File? found = await cache.cachedFile('/music/song.flac', _stamp());
    expect(found, isNotNull);
    expect(found!.path, uri.toFilePath());
    expect(found.lengthSync(), greaterThan(0));
  });

  test('different source paths cache to different files', () async {
    final Uint8List cover = await _solidPng(16, 16);
    final Uri? a = await cache.store('/music/a.flac', _stamp(), cover);
    final Uri? b = await cache.store('/music/b.flac', _stamp(), cover);

    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b));
  });

  test('two different files sharing a size and mtime do not collide', () async {
    // A stamp is explicitly not an identity (see LocalFileStamp): a rip that
    // wrote a whole album in one pass leaves plenty of files agreeing on both.
    // Only the path keeps their covers apart.
    final LocalFileStamp shared = _stamp(size: 5_242_880, mtime: 1699999999000);
    final Uri a = (await cache.store(
      '/music/album/01.flac',
      shared,
      await _solidPng(16, 16),
    ))!;
    final Uri b = (await cache.store(
      '/music/album/02.flac',
      shared,
      await _solidPng(24, 24),
    ))!;

    expect(a, isNot(b));
    expect(
      await _decodedSize(File(a.toFilePath()).readAsBytesSync()),
      const ui.Size(16, 16),
    );
    expect(
      await _decodedSize(File(b.toFilePath()).readAsBytesSync()),
      const ui.Size(24, 24),
    );
  });

  test('the cache key never contains the source path', () async {
    final Uint8List cover = await _solidPng(16, 16);
    await cache.store(
      '/home/alice/Music/Private Folder/song.flac',
      _stamp(),
      cover,
    );

    final List<FileSystemEntity> written = dir.listSync();
    expect(written, hasLength(1));
    expect(written.single.path.contains('alice'), isFalse);
    expect(written.single.path.contains('Private'), isFalse);
  });

  test('store returns null and writes nothing for empty bytes', () async {
    final Uri? uri = await cache.store(
      '/music/song.flac',
      _stamp(),
      Uint8List(0),
    );

    expect(uri, isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('store returns null for bytes that are not a decodable image', () async {
    final Uri? uri = await cache.store(
      '/music/song.flac',
      _stamp(),
      Uint8List.fromList('definitely not an image'.codeUnits),
    );

    expect(uri, isNull);
    expect(await cache.cachedFile('/music/song.flac', _stamp()), isNull);
  });

  test('a picture larger than the source cap is dropped before any decode',
      () async {
    // 17 MiB of plausible-looking PNG header plus noise: a frame whose declared
    // length is nothing a cover legitimately is. The point is that it costs no
    // decode and reaches no disk, not that it happens to be undecodable.
    final Uint8List oversized = Uint8List(17 * 1024 * 1024);
    oversized.setRange(0, 8, await _solidPng(1, 1));

    final Uri? uri = await cache.store('/music/song.flac', _stamp(), oversized);

    expect(uri, isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('a corrupt (0-byte) cache entry is treated as a miss', () async {
    final Uint8List cover = await _solidPng(16, 16);
    final Uri uri = (await cache.store('/music/song.flac', _stamp(), cover))!;
    File(uri.toFilePath()).writeAsBytesSync(<int>[]);

    expect(await cache.cachedFile('/music/song.flac', _stamp()), isNull);
  });

  test('an image within the bound is stored at its original size', () async {
    final Uint8List cover = await _solidPng(300, 150);

    final Uri uri = (await cache.store('/music/song.flac', _stamp(), cover))!;

    final ui.Size size = await _decodedSize(
      File(uri.toFilePath()).readAsBytesSync(),
    );
    expect(size.width, 300);
    expect(size.height, 150);
  });

  test('an image over the bound is downsampled, aspect ratio kept', () async {
    final Uint8List cover = await _solidPng(4000, 2000);

    final Uri uri = (await cache.store('/music/song.flac', _stamp(), cover))!;

    final ui.Size size = await _decodedSize(
      File(uri.toFilePath()).readAsBytesSync(),
    );
    expect(size.width, lessThanOrEqualTo(1024));
    expect(size.height, lessThanOrEqualTo(1024));
    expect(size.width / size.height, closeTo(2.0, 0.05));
  });

  test('storing again for the same path and stamp reuses the same entry',
      () async {
    final Uint8List small = await _solidPng(16, 16);
    final Uint8List big = await _solidPng(64, 64);
    final Uri first = (await cache.store('/music/song.flac', _stamp(), small))!;
    final Uri second = (await cache.store('/music/song.flac', _stamp(), big))!;

    expect(second, first);
    final ui.Size size = await _decodedSize(
      File(second.toFilePath()).readAsBytesSync(),
    );
    expect(size.width, 64);
  });

  group('a changed file invalidates its own entry', () {
    test('a new mtime misses, so the re-tagged cover is re-extracted',
        () async {
      await cache.store(
        '/music/song.flac',
        _stamp(mtime: 1700000000000),
        await _solidPng(16, 16),
      );

      expect(
        await cache.cachedFile(
          '/music/song.flac',
          _stamp(mtime: 1700000009000),
        ),
        isNull,
      );
    });

    test('a new size misses too', () async {
      await cache.store(
        '/music/song.flac',
        _stamp(size: 4096),
        await _solidPng(16, 16),
      );

      expect(
        await cache.cachedFile('/music/song.flac', _stamp(size: 8192)),
        isNull,
      );
    });

    test(
        'the superseded entry survives until it is swept, and the new cover '
        'is what the current stamp reads back', () async {
      final Uri old = (await cache.store(
        '/music/song.flac',
        _stamp(mtime: 1),
        await _solidPng(16, 16),
      ))!;
      final Uri fresh = (await cache.store(
        '/music/song.flac',
        _stamp(mtime: 2),
        await _solidPng(48, 48),
      ))!;

      expect(fresh, isNot(old));
      final File? current = await cache.cachedFile(
        '/music/song.flac',
        _stamp(mtime: 2),
      );
      expect(current!.path, fresh.toFilePath());

      await cache.retainOnly(<Uri>{fresh});
      expect(File(old.toFilePath()).existsSync(), isFalse);
      expect(File(fresh.toFilePath()).existsSync(), isTrue);
    });
  });

  group('retainOnly', () {
    test('keeps referenced entries and drops the rest', () async {
      final Uri kept = (await cache.store(
        '/music/kept.flac',
        _stamp(),
        await _solidPng(16, 16),
      ))!;
      final Uri orphan = (await cache.store(
        '/music/deleted.flac',
        _stamp(),
        await _solidPng(16, 16),
      ))!;

      await cache.retainOnly(<Uri>{kept});

      expect(File(kept.toFilePath()).existsSync(), isTrue);
      expect(File(orphan.toFilePath()).existsSync(), isFalse);
      expect(
        await cache.cachedFile('/music/kept.flac', _stamp()),
        isNotNull,
      );
    });

    test('an empty live set empties the cache', () async {
      await cache.store('/music/a.flac', _stamp(), await _solidPng(16, 16));
      await cache.store('/music/b.flac', _stamp(), await _solidPng(16, 16));

      await cache.retainOnly(const <Uri>{});

      expect(dir.listSync(), isEmpty);
    });

    test('abandoned .tmp writes are swept', () async {
      final File abandoned = File('${dir.path}/deadbeef.img.tmp')
        ..writeAsBytesSync(await _solidPng(8, 8));

      await cache.retainOnly(const <Uri>{});

      expect(abandoned.existsSync(), isFalse);
    });

    test('files this cache did not write are left alone', () async {
      final File foreign = File('${dir.path}/notes.txt')
        ..writeAsStringSync('someone else put this here');

      await cache.retainOnly(const <Uri>{});

      expect(foreign.existsSync(), isTrue);
    });

    test('a missing cache directory is a no-op, not a failure', () async {
      await dir.delete(recursive: true);

      await expectLater(cache.retainOnly(const <Uri>{}), completes);
    });

    test('a non-file live URI does not keep anything alive', () async {
      final Uri orphan = (await cache.store(
        '/music/song.flac',
        _stamp(),
        await _solidPng(16, 16),
      ))!;

      // Remote covers are https: and belong to a different cache entirely;
      // they must not be mistaken for a reference into this one.
      await cache
          .retainOnly(<Uri>{Uri.parse('https://example.test/cover.jpg')});

      expect(File(orphan.toFilePath()).existsSync(), isFalse);
    });

    group('never touches the user’s source audio', () {
      late Directory music;
      late File song;
      late Uint8List original;

      setUp(() async {
        music = await Directory.systemTemp.createTemp('local_artwork_source');
        original = Uint8List.fromList(
          List<int>.generate(2048, (int i) => i % 251),
        );
        song = File('${music.path}/song.flac')..writeAsBytesSync(original);
      });

      tearDown(() async {
        if (await music.exists()) await music.delete(recursive: true);
      });

      test('a sweep that empties the cache leaves the file byte-identical',
          () async {
        await cache.store(song.path, _stamp(), await _solidPng(16, 16));

        await cache.retainOnly(const <Uri>{});

        expect(song.existsSync(), isTrue);
        expect(song.readAsBytesSync(), original);
        expect(music.listSync(), hasLength(1));
      });

      test('a symlink planted in the cache is not followed to the audio file',
          () async {
        // The one way a sweep confined to its own directory could still reach
        // a source file. `followLinks: false` reports this as a Link, which is
        // not a File, so it is skipped before any delete is even considered.
        Link('${dir.path}/deadbeef.img').createSync(song.path);

        await cache.retainOnly(const <Uri>{});

        expect(song.existsSync(), isTrue);
        expect(song.readAsBytesSync(), original);
      });

      test('a live entry pointing outside the cache is still never deleted',
          () async {
        // Belt and braces: even handed the source file as a "live" URI, the
        // sweep only ever iterates its own directory, so nothing outside it is
        // a candidate either way.
        await cache.retainOnly(<Uri>{Uri.file(song.path)});

        expect(song.existsSync(), isTrue);
        expect(song.readAsBytesSync(), original);
      });
    });
  });
}
