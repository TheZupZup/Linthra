import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/services/download_state.dart';

/// Replays `test/fixtures/download_settle_cases.txt`, the cases the Rust rule
/// (native/linthra_core/src/download_settle_cases_test.rs) replays too.
void main() {
  DownloadStatus? status(String field) =>
      field == '-' ? null : DownloadStatus.values.byName(field);

  test(
    ''
    'a cancelled download settles as every shared case says',
    () {
      final List<String> lines = File('test/fixtures/download_settle_cases.txt')
          .readAsLinesSync()
          .where((String line) => line.isNotEmpty && !line.startsWith('#'))
          .toList();

      for (final String line in lines) {
        final List<String> fields = line.split('\t');
        expect(fields, hasLength(3), reason: 'bad case line "$line"');
        expect(
          settleCanceled(
            status(fields[0]),
            CommittedCopy.values.byName(fields[1]),
          ),
          status(fields[2]),
          reason: 'case "$line"',
        );
      }
      // Every row (none, or one of the four kept in the map) with every copy.
      expect(lines, hasLength(15));
    },
  );
}
