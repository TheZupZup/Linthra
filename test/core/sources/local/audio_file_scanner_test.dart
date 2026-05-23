import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon/core/sources/local/audio_file_scanner.dart';

void main() {
  group('IoAudioFileScanner', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('halcyon_scan_test');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('lists every file recursively, including non-audio files', () async {
      final nested = Directory('${root.path}/Album')..createSync();
      File('${root.path}/a.mp3').writeAsStringSync('x');
      File('${nested.path}/b.flac').writeAsStringSync('x');
      File('${nested.path}/notes.txt').writeAsStringSync('x');

      const scanner = IoAudioFileScanner();
      final files = await scanner.listFiles(root.path);

      expect(files, hasLength(3));
      expect(files.every((path) => File(path).existsSync()), isTrue);
      expect(files.any((path) => path.endsWith('a.mp3')), isTrue);
      expect(files.any((path) => path.endsWith('b.flac')), isTrue);
      expect(files.any((path) => path.endsWith('notes.txt')), isTrue);
    });

    test('returns an empty list for a folder that does not exist', () async {
      const scanner = IoAudioFileScanner();
      final files = await scanner.listFiles('${root.path}/missing');
      expect(files, isEmpty);
    });
  });
}
