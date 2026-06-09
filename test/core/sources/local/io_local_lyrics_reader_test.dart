import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/io_local_lyrics_reader.dart';
import 'package:path/path.dart' as p;

void main() {
  group('IoLocalLyricsReader', () {
    late Directory dir;
    const IoLocalLyricsReader reader = IoLocalLyricsReader();

    setUp(() {
      dir = Directory.systemTemp.createTempSync('linthra_lyrics_test');
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    String trackPath() => p.join(dir.path, 'Song.mp3');

    test('reads the sidecar with the matching base name and extension',
        () async {
      File(p.join(dir.path, 'Song.lrc')).writeAsStringSync('[00:01.00]hello\n');

      final String? text = await reader.readSidecar(trackPath(), 'lrc');

      expect(text, '[00:01.00]hello\n');
    });

    test('reads a .txt sidecar', () async {
      File(p.join(dir.path, 'Song.txt')).writeAsStringSync('plain lyrics\n');

      expect(await reader.readSidecar(trackPath(), 'txt'), 'plain lyrics\n');
    });

    test('returns null when no sidecar exists', () async {
      expect(await reader.readSidecar(trackPath(), 'lrc'), isNull);
      expect(await reader.readSidecar(trackPath(), 'txt'), isNull);
    });

    test('does not match a different base name', () async {
      File(p.join(dir.path, 'Other.lrc')).writeAsStringSync('nope\n');

      expect(await reader.readSidecar(trackPath(), 'lrc'), isNull);
    });

    test('accepts a file:// URI', () async {
      File(p.join(dir.path, 'Song.lrc')).writeAsStringSync('from uri\n');
      final String fileUri = Uri.file(trackPath()).toString();

      expect(await reader.readSidecar(fileUri, 'lrc'), 'from uri\n');
    });

    test('returns null for a content:// URI (not its job)', () async {
      const String contentUri = 'content://com.android.externalstorage'
          '.documents/tree/primary%3AMusic/document/primary%3AMusic%2FSong.mp3';

      expect(await reader.readSidecar(contentUri, 'lrc'), isNull);
    });

    test('finds the sidecar in the same nested folder as the track', () async {
      final Directory nested = Directory(p.join(dir.path, 'Artist', 'Album'))
        ..createSync(
          recursive: true,
        );
      final String track = p.join(nested.path, 'Track.flac');
      File(p.join(nested.path, 'Track.lrc')).writeAsStringSync('nested\n');

      expect(await reader.readSidecar(track, 'lrc'), 'nested\n');
    });
  });
}
