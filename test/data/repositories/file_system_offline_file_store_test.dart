import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/data/repositories/file_system_offline_file_store.dart';

import '../../support/offline_file_writes.dart';

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

  group('FileSystemOfflineFileStore drafts (#745)', () {
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

    List<String> names() =>
        <String>[for (final FileSystemEntity e in tempDir.listSync()) e.path]
            .map((String path) => path.split(Platform.pathSeparator).last)
            .toList();

    test(
        'chunks reach a temp file as they are added, the cache file only '
        'appears once published', () async {
      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3]);

      final File temp = File('${tempDir.path}/${names().single}');
      expect(temp.path, endsWith('.part'));
      expect(await temp.length(), 3);
      expect(await store.pathFor('t1.mp3'), isNull);

      await draft.add(const <int>[4, 5]);
      expect(draft.length, 5);
      final String fileName = await draft.publish(extension: 'mp3');

      expect(fileName, 't1.mp3');
      expect(names(), <String>['t1.mp3']);
      expect(
        await File((await store.pathFor(fileName))!).readAsBytes(),
        <int>[1, 2, 3, 4, 5],
      );
    });

    test('two drafts of the same track each have their own temp file',
        () async {
      final OfflineFileDraft download = await store.createDraft('t1');
      final OfflineFileDraft precache = await store.createDraft('t1');
      await download.add(const <int>[1, 1, 1]);
      await precache.add(const <int>[2, 2]);

      expect(names(), hasLength(2));
      await precache.discard();
      final String fileName = await download.publish(extension: 'mp3');

      expect(names(), <String>['t1.mp3']);
      expect(
        await File((await store.pathFor(fileName))!).readAsBytes(),
        <int>[1, 1, 1],
      );
    });

    test('discarding deletes the temp file, and is safe to repeat', () async {
      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3]);

      await draft.discard();
      await draft.discard();

      expect(tempDir.listSync(), isEmpty);
      await expectLater(draft.add(const <int>[4]), throwsStateError);
      await expectLater(draft.publish(), throwsStateError);
    });

    test('a flush that fails still closes the file, and leaves no temp',
        () async {
      late _FailingFlush opened;
      store = FileSystemOfflineFileStore(
        directory: () async => tempDir,
        openDraft: (File temp) async =>
            opened = _FailingFlush(await temp.open(mode: FileMode.writeOnly)),
      );
      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3]);

      await expectLater(
        draft.publish(extension: 'mp3'),
        throwsA(isA<FileSystemException>()),
      );

      expect(opened.closed, isTrue);
      expect(tempDir.listSync(), isEmpty);
    });

    test('discarding after publishing keeps the published file', () async {
      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3]);
      final String fileName = await draft.publish(extension: 'mp3');

      await draft.discard();

      expect(await store.sizeFor(fileName), 3);
      await expectLater(draft.add(const <int>[4]), throwsStateError);
    });

    test('a draft left behind by a crash is cleared at the next launch',
        () async {
      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3]);
      // The process died here: the draft was never published or discarded.
      final File left = File('${tempDir.path}/${names().single}');
      await left.setLastModified(
        DateTime.now().subtract(const Duration(minutes: 5)),
      );

      final FileSystemOfflineFileStore next =
          FileSystemOfflineFileStore(directory: () async => tempDir);
      await next.removeAbandoned(<String>{});

      expect(tempDir.listSync(), isEmpty);
    });

    test('a draft still being written is never taken by the sweep', () async {
      final OfflineFileDraft draft = await store.createDraft('t1');
      await draft.add(const <int>[1, 2, 3]);

      await store.removeAbandoned(<String>{});
      await draft.add(const <int>[4]);

      expect(await draft.publish(extension: 'mp3'), 't1.mp3');
      expect(await store.sizeFor('t1.mp3'), 4);
    });
  });
}

/// An open file whose flush fails, the way it does once the disk is full.
class _FailingFlush implements RandomAccessFile {
  _FailingFlush(this._inner);

  final RandomAccessFile _inner;
  bool closed = false;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    await _inner.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async =>
      throw const FileSystemException('No space left on device');

  @override
  Future<void> close() async {
    closed = true;
    await _inner.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
