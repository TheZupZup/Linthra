import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/search_rank.dart';

/// Replays `test/fixtures/search_rank_cases.txt`, the cases the Rust rule
/// (native/linthra_core/src/search_rank_cases_test.rs) replays too.
void main() {
  final List<String> lines = File('test/fixtures/search_rank_cases.txt')
      .readAsLinesSync()
      .where((String line) => line.isNotEmpty && !line.startsWith('#'))
      .toList();

  test(
    'mixed results are ordered as every '
    'shared case says',
    () {
      for (final String line in lines) {
        final List<String> f = line.split('\t');
        expect(f, hasLength(3), reason: 'bad case line "$line"');
        final List<(SearchResultKind, String)> results =
            <(SearchResultKind, String)>[
          for (final String entry in f[1].split('|'))
            (
              SearchResultKind.values.byName(entry.split(':').first),
              entry.substring(entry.indexOf(':') + 1),
            ),
        ];
        expect(
          rankSearchResults(f[0], results),
          <int>[for (final String p in f[2].split(' ')) int.parse(p)],
          reason: 'case "$line"',
        );
      }
      expect(lines.length, greaterThanOrEqualTo(12));
    },
  );
}
