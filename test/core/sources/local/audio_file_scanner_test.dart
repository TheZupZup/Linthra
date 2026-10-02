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

/// A subfolder that refuses to be listed, the way one whose permissions
/// changed or a stale network mount inside the music folder does.
class _Unlistable implements Directory {
  _Unlistable(this.path);

  @override
  final String path;

  @override
  Directory get absolute => this;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      Stream<FileSystemEntity>.error(
        FileSystemException(
          'Directory listing failed',
          path,
          const OSError('Permission denied', 13),
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The real folder, except that its listing hands back [_locked] as an
/// [_Unlistable] subfolder.
class _HidesOneSubfolder implements Directory {
  _HidesOneSubfolder(this._real, this._locked);

  final Directory _real;
  final String _locked;

  @override
  String get path => _real.path;

  @override
  Directory get absolute => this;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      _real.list(recursive: recursive, followLinks: followLinks).map(
            (FileSystemEntity entity) =>
                entity.path == _locked ? _Unlistable(entity.path) : entity,
          );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Makes [locked], directly under [root], unlistable to a walk of [root].
///
/// The entries a listing yields don't go through [IOOverrides], so the swap
/// happens in the listing of the folder above it. No permissions change and
/// no process runs, so this works the same as root and as a normal user.
final class _LockedSubfolder extends IOOverrides {
  _LockedSubfolder({required this.root, required this.locked});

  final String root;
  final String locked;

  @override
  Directory createDirectory(String path) {
    final Directory real = super.createDirectory(path);
    return path == root ? _HidesOneSubfolder(real, locked) : real;
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

      final List<String> unreadable = <String>[];
      const scanner = IoAudioFileScanner();
      final files = await IOOverrides.runWithIOOverrides(
        () => scanner.listFiles(
          root.path,
          onUnreadableDirectory: unreadable.add,
        ),
        _LockedSubfolder(root: root.path, locked: locked.path),
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
