import 'dart:async';
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

/// How long the stall tests let a listing go without an answer.
const Duration _stall = Duration(milliseconds: 50);

/// A folder on storage that stopped answering: its listing never yields an
/// entry, never fails and never ends, the way one on an NFS hard mount whose
/// server went away blocks.
class _Silent implements Directory {
  _Silent(this.path, {this.onList});

  @override
  final String path;

  /// Called each time something starts listing this folder.
  final void Function()? onList;

  @override
  Directory get absolute => this;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) {
    onList?.call();
    return StreamController<FileSystemEntity>().stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [silent] stops answering, and so does every folder [root] lists when
/// [everySubfolder] is set: a share that went away just after the walk read
/// its top folder.
final class _StalledShare extends IOOverrides {
  _StalledShare({
    required this.root,
    this.silent = const <String>{},
    this.everySubfolder = false,
  });

  final String root;
  final Set<String> silent;
  final bool everySubfolder;
  int stalledListings = 0;

  @override
  Directory createDirectory(String path) {
    if (silent.contains(path)) {
      return _Silent(path, onList: () => stalledListings++);
    }
    final Directory real = super.createDirectory(path);
    if (path != root) return real;
    return _Listing(real, (FileSystemEntity entity) {
      if (entity is! Directory) return entity;
      if (!everySubfolder && !silent.contains(entity.path)) return entity;
      return _Silent(entity.path, onList: () => stalledListings++);
    });
  }
}

/// The real folder, its listing passed through [_swap].
class _Listing implements Directory {
  _Listing(this._real, this._swap);

  final Directory _real;
  final FileSystemEntity Function(FileSystemEntity entity) _swap;

  @override
  String get path => _real.path;

  @override
  Directory get absolute => this;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      _real.list(recursive: recursive, followLinks: followLinks).map(_swap);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The selected folder answers, whenever it is asked.
class _Present implements DirectoryReadability {
  const _Present();

  @override
  Future<LocalRootFault?> inspect(String path) async => null;
}

/// The selected folder is asked whether it is still there, and never answers.
class _NeverAnswers implements DirectoryReadability {
  const _NeverAnswers();

  @override
  Future<LocalRootFault?> inspect(String path) =>
      Completer<LocalRootFault?>().future;
}

/// The selected folder doesn't answer any more, and [asked] counts how often
/// it was asked.
class _NotAnswering implements DirectoryReadability {
  int asked = 0;

  @override
  Future<LocalRootFault?> inspect(String path) async {
    asked++;
    return LocalRootFault.unavailable;
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

    group('storage that stops answering (#778)', () {
      test('a selected folder whose listing never answers is unavailable',
          () async {
        const scanner = IoAudioFileScanner(
          presence: _Present(),
          stallLimit: _stall,
        );

        await expectLater(
          IOOverrides.runWithIOOverrides(
            () => scanner.listFiles(root.path),
            _StalledShare(root: '', silent: <String>{root.path}),
          ),
          throwsA(
            isA<FolderScanException>().having(
              (FolderScanException error) => error.code,
              'code',
              LocalRootFault.unavailable.code,
            ),
          ),
        );
      });

      test(
          'a folder that never answers the check after the walk is '
          'unavailable', () async {
        File('${root.path}/a.mp3').writeAsStringSync('x');
        const scanner = IoAudioFileScanner(
          presence: _NeverAnswers(),
          stallLimit: _stall,
        );

        await expectLater(
          scanner.listFiles(root.path),
          throwsA(
            isA<FolderScanException>().having(
              (FolderScanException error) => error.code,
              'code',
              LocalRootFault.unavailable.code,
            ),
          ),
        );
      });

      test(
          'a subfolder that stops answering is skipped while the selected '
          'folder still answers', () async {
        // A share mounted inside the music folder, whose server went away.
        final String share = '${root.path}/Share';
        Directory(share).createSync();
        File('$share/hidden.mp3').writeAsStringSync('x');
        Directory('${root.path}/Open').createSync();
        File('${root.path}/Open/seen.mp3').writeAsStringSync('x');

        final List<String> unreadable = <String>[];
        const scanner = IoAudioFileScanner(
          presence: _Present(),
          stallLimit: _stall,
        );
        final List<String> files = await IOOverrides.runWithIOOverrides(
          () => scanner.listFiles(
            root.path,
            onUnreadableDirectory: unreadable.add,
          ),
          _StalledShare(root: root.path, silent: <String>{share}),
        );

        expect(unreadable, <String>[share]);
        expect(files.any((String path) => path.endsWith('seen.mp3')), isTrue);
        expect(
          files.any((String path) => path.endsWith('hidden.mp3')),
          isFalse,
        );
      });

      test(
          'once the selected folder stops answering too, the walk ends at the '
          'first folder that stalled', () async {
        // The whole share went away after its top folder was read: every
        // folder still to list would stall, one limit after the other.
        for (final String name in <String>['A', 'B', 'C', 'D']) {
          Directory('${root.path}/$name').createSync();
          File('${root.path}/$name/song.mp3').writeAsStringSync('x');
        }
        final _NotAnswering presence = _NotAnswering();
        final IoAudioFileScanner scanner = IoAudioFileScanner(
          presence: presence,
          stallLimit: _stall,
        );
        final _StalledShare share =
            _StalledShare(root: root.path, everySubfolder: true);

        await expectLater(
          IOOverrides.runWithIOOverrides(
            () => scanner.listFiles(root.path),
            share,
          ),
          throwsA(
            isA<FolderScanException>().having(
              (FolderScanException error) => error.code,
              'code',
              LocalRootFault.unavailable.code,
            ),
          ),
        );
        expect(share.stalledListings, 1);
        expect(presence.asked, 1);
      });
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
