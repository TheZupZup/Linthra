import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';

void main() {
  group('IoDirectoryReadability', () {
    const readability = IoDirectoryReadability();

    test('reports a populated directory as readable', () async {
      final dir = await Directory.systemTemp.createTemp('linthra_readable_');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/One.mp3').writeAsString('x');

      expect(await readability.canList(dir.path), isTrue);
      expect(await readability.inspect(dir.path), isNull);
    });

    test('reports an empty but readable directory as readable', () async {
      // An empty music folder is an ordinary thing to have, and calling it
      // unreachable would send the user looking for a drive that is plugged in.
      final dir = await Directory.systemTemp.createTemp('linthra_empty_');
      addTearDown(() => dir.delete(recursive: true));

      expect(await readability.canList(dir.path), isTrue);
      expect(await readability.inspect(dir.path), isNull);
    });

    test('reports a missing directory as not readable', () async {
      final dir = await Directory.systemTemp.createTemp('linthra_missing_');
      final missing = '${dir.path}/does-not-exist';
      await dir.delete(recursive: true);

      expect(await readability.canList(missing), isFalse);
    });

    test('says a missing directory is missing, not merely unusable', () async {
      // The distinction #414 is built on. "Not readable" covers a deleted
      // folder, a folder whose permissions changed and a share that stopped
      // answering, and those three have three different fixes.
      final dir = await Directory.systemTemp.createTemp('linthra_missing_why_');
      final missing = '${dir.path}/does-not-exist';
      await dir.delete(recursive: true);

      expect(await readability.inspect(missing), LocalRootFault.missing);
    });

    test('a path that turned out to be a file is missing, not empty', () async {
      // The selection names a folder; a file where the folder used to be is the
      // folder being gone. It must never read as "readable but empty", which
      // would be persisted as a successful scan of no music.
      final dir = await Directory.systemTemp.createTemp('linthra_not_a_dir_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/One.mp3';
      await File(path).writeAsString('x');

      expect(await readability.inspect(path), LocalRootFault.missing);
    });
  });
}
