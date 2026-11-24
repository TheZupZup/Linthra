import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/queue_moves.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// Replays `test/fixtures/queue_moves_cases.txt`, the cases the Rust rule
/// (native/linthra_core/src/queue_moves_cases_test.rs) replays too.
void main() {
  int? optional(String field) => field == '-' ? null : int.parse(field);

  final List<String> lines = File('test/fixtures/queue_moves_cases.txt')
      .readAsLinesSync()
      .where((String line) => line.isNotEmpty && !line.startsWith('#'))
      .toList();

  for (final bool useNative in <bool>[false, true]) {
    test(
      '${useNative ? 'Rust' : 'Dart'}: a queue move lands as every shared '
      'case says',
      skip:
          useNative && !LinthraCore.isAvailable ? 'Rust core not built' : false,
      () {
        for (final String line in lines) {
          final List<String> f = line.split('\t');
          expect(f, hasLength(5), reason: 'bad case line "$line"');
          expect(
            queueMoveTarget(
              QueueMove.values.byName(f[2]),
              length: int.parse(f[0]),
              current: int.parse(f[1]),
              index: optional(f[3]) ?? 0,
              useNative: useNative,
            ),
            optional(f[4]),
            reason: 'case "$line"',
          );
        }
        expect(lines, hasLength(30));
      },
    );
  }
}
