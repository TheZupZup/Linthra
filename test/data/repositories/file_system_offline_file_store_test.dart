import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/file_system_offline_file_store.dart';

void main() {
  group('FileSystemOfflineFileStore', () {
    late Directory tempDir;
    late FileSystemOfflineFileStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('linthra_offline_test');
      store = FileSystemOfflineFileStore(directory: () async => tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('writes bytes and resolves the file back', () async {
      final String fileName =
          await store.write('t1', const <int>[1, 2, 3, 4], extension: 'mp3');

      expect(fileName, 't1.mp3');
      final String? path = await store.pathFor(fileName);
      expect(path, isNotNull);
      expect(await File(path!).readAsBytes(), <int>[1, 2, 3, 4]);
    });

    test('the file name is derived from the id and carries no separators',
        () async {
      // An id with unsafe characters must not escape the offline directory.
      final String fileName = await store.write(
        'weird/../id with spaces',
        const <int>[0],
        extension: 'flac',
      );

      expect(fileName, isNot(contains('/')));
      expect(fileName, isNot(contains(' ')));
      expect(fileName, endsWith('.flac'));
      // The written file lives directly under the offline directory.
      final String? path = await store.pathFor(fileName);
      expect(path, isNotNull);
      expect(File(path!).parent.path, tempDir.path);
    });

    test('omits the extension when none is given', () async {
      final String fileName = await store.write('t2', const <int>[9]);
      expect(fileName, 't2');
    });

    test('pathFor returns null for a file that was never written', () async {
      expect(await store.pathFor('missing.mp3'), isNull);
    });

    test('sizeFor returns the byte length on disk', () async {
      final String fileName =
          await store.write('t1', const <int>[1, 2, 3, 4, 5], extension: 'mp3');

      expect(await store.sizeFor(fileName), 5);
    });

    test('sizeFor returns null for a file that was never written', () async {
      expect(await store.sizeFor('missing.mp3'), isNull);
    });

    test('sizeFor returns null after the file is deleted', () async {
      final String fileName =
          await store.write('t1', const <int>[1, 2], extension: 'mp3');
      await store.delete(fileName);

      expect(await store.sizeFor(fileName), isNull);
    });

    test('delete removes the cached file', () async {
      final String fileName =
          await store.write('t1', const <int>[1], extension: 'mp3');
      expect(await store.pathFor(fileName), isNotNull);

      await store.delete(fileName);

      expect(await store.pathFor(fileName), isNull);
    });

    test('delete is a no-op for a missing file', () async {
      await store.delete('missing.mp3');
    });

    test('an atomic write leaves only the final file — no .part temp behind',
        () async {
      final String fileName =
          await store.write('t1', const <int>[1, 2, 3], extension: 'mp3');

      // The temp sibling was renamed into place, not left alongside the result.
      final List<FileSystemEntity> entries = tempDir.listSync();
      expect(entries, hasLength(1));
      expect(entries.single.path, endsWith(fileName));
      expect(entries.single.path, isNot(endsWith('.part')));
    });

    test('refuses to cache an empty download, publishing no file', () async {
      await expectLater(
        store.write('t1', const <int>[], extension: 'mp3'),
        throwsA(isA<FileSystemException>()),
      );

      // Nothing was published and no temp was left behind, so the locator finds
      // no file and playback falls back to streaming.
      expect(await store.pathFor('t1.mp3'), isNull);
      expect(tempDir.listSync(), isEmpty);
    });

    test('a re-download atomically replaces the prior cached bytes', () async {
      final String fileName =
          await store.write('t1', const <int>[1, 1, 1], extension: 'mp3');
      final String again =
          await store.write('t1', const <int>[2, 2], extension: 'mp3');

      expect(again, fileName);
      final String? path = await store.pathFor(fileName);
      expect(await File(path!).readAsBytes(), <int>[2, 2]);
      // Still exactly one file: the temp was renamed over the old copy, not
      // accumulated alongside it.
      expect(tempDir.listSync(), hasLength(1));
    });
  });
}
