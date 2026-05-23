import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';

void main() {
  group('IoDirectoryReadability', () {
    const readability = IoDirectoryReadability();

    test('reports a populated directory as readable', () async {
      final dir = await Directory.systemTemp.createTemp('linthra_readable_');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/One.mp3').writeAsString('x');

      expect(await readability.canList(dir.path), isTrue);
    });

    test('reports an empty but readable directory as readable', () async {
      final dir = await Directory.systemTemp.createTemp('linthra_empty_');
      addTearDown(() => dir.delete(recursive: true));

      expect(await readability.canList(dir.path), isTrue);
    });

    test('reports a missing directory as not readable', () async {
      final dir = await Directory.systemTemp.createTemp('linthra_missing_');
      final missing = '${dir.path}/does-not-exist';
      await dir.delete(recursive: true);

      expect(await readability.canList(missing), isFalse);
    });
  });
}
