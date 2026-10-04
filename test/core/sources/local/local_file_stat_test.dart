// IoLocalFileStatReader.isGone, on a real folder: the evidence that a file the
// walk listed and could then not read is gone, rather than out of reach.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:path/path.dart' as p;

/// A folder listing that fails, the way one on storage that stopped answering
/// does.
class _Unlistable implements Directory {
  _Unlistable(this._real);

  final Directory _real;

  @override
  String get path => _real.path;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      Stream<FileSystemEntity>.error(
        FileSystemException('Input/output error', path, const OSError('', 5)),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _UnlistableFolders extends IOOverrides {
  _UnlistableFolders(this.folders);

  final Set<String> folders;

  @override
  Directory createDirectory(String path) {
    final Directory real = super.createDirectory(path);
    return folders.contains(path) ? _Unlistable(real) : real;
  }
}

void main() {
  late Directory sandbox;
  late String root;
  const IoLocalFileStatReader reader = IoLocalFileStatReader();

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('linthra_file_absence_');
    root = p.join(sandbox.path, 'Music');
    Directory(p.join(root, 'Bon Iver', 'Bon Iver')).createSync(recursive: true);
  });

  tearDown(() => sandbox.delete(recursive: true));

  String file(String relative) {
    final String path = p.join(root, relative);
    File(path).writeAsStringSync('');
    return path;
  }

  group('isGone', () {
    test('a file its folder still lists is not gone', () async {
      final String path = file('Bon Iver/Bon Iver/05 Holocene.flac');

      expect(await reader.isGone(path, root: root), isFalse);
    });

    test('a file its folder lists no more is gone', () async {
      final String path = file('Bon Iver/Bon Iver/05 Holocene.flac');
      File(path).renameSync(p.join(root, 'Holocene.flac'));

      expect(await reader.isGone(path, root: root), isTrue);
    });

    test('a file in a folder that moved away is gone', () async {
      final String path = file('Bon Iver/Bon Iver/05 Holocene.flac');
      Directory(p.join(root, 'Bon Iver')).renameSync(p.join(root, 'Elsewhere'));

      expect(await reader.isGone(path, root: root), isTrue);
    });

    test('a file whose folder cannot be listed is not known to be gone',
        () async {
      // The folder above still lists it, so it is there, out of reach.
      final String folder = p.join(root, 'Bon Iver', 'Bon Iver');
      final String path = file('Bon Iver/Bon Iver/05 Holocene.flac');

      final bool gone = await IOOverrides.runWithIOOverrides(
        () => reader.isGone(path, root: root),
        _UnlistableFolders(<String>{folder}),
      );

      expect(gone, isFalse);
    });

    test('nothing is gone when the selected folder itself cannot be listed',
        () async {
      // A drive that went away: its folders cannot be listed up to the root,
      // and nothing above the root is asked.
      final String path = file('Bon Iver/Bon Iver/05 Holocene.flac');
      await sandbox.delete(recursive: true);
      await Directory(sandbox.path).create();

      expect(await reader.isGone(path, root: root), isFalse);
    });

    test('a path outside the selected folder is never gone', () async {
      expect(
        await reader.isGone(p.join(sandbox.path, 'other.flac'), root: root),
        isFalse,
      );
    });
  });
}
