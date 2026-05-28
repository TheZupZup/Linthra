import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
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

    test('streams bytes to a temp file and atomically commits it', () async {
      final OfflineTempFile temp = await store.writeTemp(
        'streamed',
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2],
          <int>[3, 4],
        ]),
        extension: 'flac',
      );

      expect(temp.sizeBytes, 4);
      expect(await File(temp.id).exists(), isTrue);
      final String fileName =
          await store.commitTemp('streamed', temp, extension: 'flac');

      expect(fileName, 'streamed.flac');
      expect(await File(temp.id).exists(), isFalse);
      final String? path = await store.pathFor(fileName);
      expect(await File(path!).readAsBytes(), <int>[1, 2, 3, 4]);
    });

    test('writeTemp deletes a partial temp file when the stream fails', () async {
      late String? tempPath;
      final Stream<List<int>> chunks = (() async* {
        yield <int>[1, 2];
        throw StateError('boom');
      })();

      await expectLater(
        store.writeTemp('broken', chunks),
        throwsA(isA<StateError>()),
      );

      final List<FileSystemEntity> files = await tempDir.list().toList();
      tempPath = files.isEmpty ? null : files.first.path;
      expect(tempPath, isNull);
    });

    test('deleteTemp removes a staged file', () async {
      final OfflineTempFile temp = await store.writeTemp(
        'cancelled',
        Stream<List<int>>.value(<int>[9]),
      );
      expect(await File(temp.id).exists(), isTrue);

      await store.deleteTemp(temp);

      expect(await File(temp.id).exists(), isFalse);
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
  });
}
