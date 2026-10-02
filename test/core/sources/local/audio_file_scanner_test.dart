import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';

/// The selected folder is no longer there once the walk is done: what an
/// unplugged drive looks like to the check at the end of the walk.
class _Gone implements DirectoryReadability {
  const _Gone();

  @override
  Future<LocalRootFault?> inspect(String path) async => LocalRootFault.missing;
}

Future<void> _chmod(String mode, String path) async {
  final ProcessResult result = await Process.run('chmod', <String>[mode, path]);
  if (result.exitCode != 0) {
    throw StateError('chmod $mode failed: ${result.stderr}');
  }
}

/// Whether this process can list [directory] despite its permissions, which
/// is true for root and anything else holding CAP_DAC_READ_SEARCH.
bool _canStillList(Directory directory) {
  try {
    directory.listSync();
    return true;
  } on FileSystemException {
    return false;
  }
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

    test('reports a subfolder it cannot list, and still lists its siblings',
        () async {
      // A subfolder whose permissions changed, or a network mount inside the
      // music folder that went stale, cannot be listed. The walk skips it
      // rather than failing the whole scan, and has to say so: every file
      // under it is missing from the result, and a caller that cannot tell
      // "not listed" from "not there" would conclude they were all deleted.
      final Directory locked = Directory('${root.path}/Locked')..createSync();
      final Directory open = Directory('${root.path}/Open')..createSync();
      File('${locked.path}/hidden.mp3').writeAsStringSync('x');
      File('${open.path}/seen.mp3').writeAsStringSync('x');
      File('${root.path}/top.mp3').writeAsStringSync('x');
      await _chmod('000', locked.path);
      // Runs before the group's tearDown, so the folder can be deleted.
      addTearDown(() => _chmod('700', locked.path));
      if (_canStillList(locked)) {
        markTestSkipped(
          'This process lists directories regardless of their permissions '
          '(it runs as root, or holds CAP_DAC_READ_SEARCH), so no folder can '
          'be made unreadable to it. CI runs this as a normal user.',
        );
        return;
      }

      final List<String> unreadable = <String>[];
      const scanner = IoAudioFileScanner();
      final files = await scanner.listFiles(
        root.path,
        onUnreadableDirectory: unreadable.add,
      );

      expect(unreadable, <String>[locked.absolute.path]);
      expect(files, hasLength(2));
      expect(files.any((path) => path.endsWith('seen.mp3')), isTrue);
      expect(files.any((path) => path.endsWith('top.mp3')), isTrue);
    });

    test('reports nothing for a walk that read every folder', () async {
      Directory('${root.path}/Album/Disc 2').createSync(recursive: true);
      File('${root.path}/Album/Disc 2/a.flac').writeAsStringSync('x');
      final List<String> unreadable = <String>[];

      const scanner = IoAudioFileScanner();
      final files = await scanner.listFiles(
        root.path,
        onUnreadableDirectory: unreadable.add,
      );

      expect(files, hasLength(1));
      expect(unreadable, isEmpty);
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
