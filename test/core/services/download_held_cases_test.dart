import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/download_state.dart';

/// Replays `test/fixtures/download_held_cases.txt`, the cases the Rust rule
/// (native/linthra_core/src/download_held_cases_test.rs) replays too.
void main() {
  test(
    ''
    'a held download is retried or dropped as every shared case says',
    () {
      final List<String> lines = File('test/fixtures/download_held_cases.txt')
          .readAsLinesSync()
          .where((String line) => line.isNotEmpty && !line.startsWith('#'))
          .toList();

      for (final String line in lines) {
        final List<String> fields = line.split('\t');
        expect(fields, hasLength(4), reason: 'bad case line "$line"');
        expect(
          heldAction(
            sameAccount: bool.parse(fields[0]),
            inFlight: bool.parse(fields[1]),
            row: fields[2] == '-'
                ? null
                : DownloadStatus.values.byName(fields[2]),
          ),
          HeldAction.values.byName(fields[3]),
          reason: 'case "$line"',
        );
      }
      // Same account or not, in flight or not, with every row.
      expect(lines, hasLength(20));
    },
  );
}
