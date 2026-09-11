import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';

/// The selected folder is no longer there once the walk is done: what an
/// unplugged drive looks like to the check at the end of the walk.
class _Gone implements DirectoryReadability {
  const _Gone();

  @override
  Future<bool> canList(String path) async => false;
}

void main() {
  group('IoAudioFileScanner', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('linthra_scan_test');
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

    test('walks several directory levels deep', () async {
      final albumDir = Directory('${root.path}/Artist/Album');
      albumDir.createSync(recursive: true);
      final discDir = Directory('${albumDir.path}/Disc 2');
      discDir.createSync();
      // An empty directory in the tree must not break the walk.
      Directory('${root.path}/Empty').createSync();
      File('${root.path}/top.mp3').writeAsStringSync('x');
      File('${albumDir.path}/mid.flac').writeAsStringSync('x');
      File('${discDir.path}/deep.ogg').writeAsStringSync('x');

      const scanner = IoAudioFileScanner();
      final files = await scanner.listFiles(root.path);

      expect(files, hasLength(3));
      expect(files.any((path) => path.endsWith('top.mp3')), isTrue);
      expect(files.any((path) => path.endsWith('mid.flac')), isTrue);
      expect(files.any((path) => path.endsWith('deep.ogg')), isTrue);
    });

    test('raises a recoverable scan error when the drive goes mid-scan',
        () async {
      // The removable-drive case (#415). The folder was there when the walk
      // started, so the walk produced *some* files, but every directory still
      // pending when the mount went away failed, and those are deliberately
      // skipped so one unreadable subfolder cannot fail a whole scan. Reporting
      // that half-walk as a complete scan would conclude that every file it
      // never reached had been deleted, which is how unplugging a drive would
      // erase the user's index of it.
      Directory('${root.path}/Album').createSync();
      File('${root.path}/a.mp3').writeAsStringSync('x');
      const scanner = IoAudioFileScanner(presence: _Gone());

      await expectLater(
        scanner.listFiles(root.path),
        throwsA(
          isA<FolderScanException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('disconnected while it was being scanned'),
              contains('Reconnect it'),
            ),
          ),
        ),
      );
    });

    test('raises a recoverable scan error for a folder that is gone', () async {
      // A selected folder that no longer resolves — unmounted drive, deleted
      // folder, or a revoked Flatpak portal document — must not look like a
      // successful scan of an empty folder: that result would be persisted and
      // would wipe a catalog the user's files are still behind.
      const scanner = IoAudioFileScanner();

      await expectLater(
        scanner.listFiles('${root.path}/missing'),
        throwsA(
          isA<FolderScanException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains("couldn't find the selected folder"),
              contains('selecting the folder again'),
            ),
          ),
        ),
      );
    });
  });
}
