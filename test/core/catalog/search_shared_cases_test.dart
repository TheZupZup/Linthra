import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/search_tokens.dart';
import 'package:linthra/core/catalog/search_typos.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// Replays test/fixtures/search_cases.txt, the cases the Rust core
/// (native/linthra_core/src/shared_cases_test.rs) replays too. Rust is the
/// reference: a failure here means the Library's direct filters, which cut
/// words and match typos in Dart, would find something the Rust index
/// doesn't, or miss something it finds.
const String _casesPath = 'test/fixtures/search_cases.txt';

/// Undoes the fixture's escapes: \t, \n, \\ and \u{HEX}.
String _unescape(String field) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < field.length) {
    final String c = field[i];
    if (c != r'\') {
      out.write(c);
      i++;
      continue;
    }
    final String next = field[i + 1];
    switch (next) {
      case 't':
        out.write('\t');
        i += 2;
      case 'n':
        out.write('\n');
        i += 2;
      case r'\':
        out.write(r'\');
        i += 2;
      case 'u':
        final int close = field.indexOf('}', i);
        out.writeCharCode(int.parse(field.substring(i + 3, close), radix: 16));
        i = close + 1;
      default:
        throw FormatException('unknown escape \\$next in $field');
    }
  }
  return out.toString();
}

/// A field, with a lone `-` meaning none.
String? _optional(String field) => field == '-' ? null : _unescape(field);

List<List<String>> _cases() => <List<String>>[
      for (final String line in File(_casesPath).readAsLinesSync())
        if (line.isNotEmpty && !line.startsWith('#')) line.split('\t'),
    ];

void main() {
  test('tokens match the shared cases', () {
    int seen = 0;
    for (final List<String> fields in _cases()) {
      if (fields[0] != 'T') continue;
      final String text = _optional(fields[1]) ?? '';
      final List<String> expected =
          _optional(fields[2])?.split(' ') ?? const <String>[];
      expect(searchTokens(text), expected, reason: 'tokens of "$text"');
      seen++;
    }
    expect(seen, greaterThan(0), reason: 'no T cases read');
  });

  test('typos match the shared cases', () {
    int seen = 0;
    for (final List<String> fields in _cases()) {
      if (fields[0] != 'F') continue;
      expect(
        matchesWithTypos(_unescape(fields[1]), _unescape(fields[2])),
        bool.parse(fields[3]),
        reason: 'typo case $fields',
      );
      seen++;
    }
    expect(seen, greaterThan(0), reason: 'no F cases read');
  });

  test('the Rust index matches the shared cases', () {
    final List<NativeSearchRecord> tracks = <NativeSearchRecord>[];
    final List<(String, List<int>)> queries = <(String, List<int>)>[];
    for (final List<String> fields in _cases()) {
      switch (fields[0]) {
        case 'R':
          tracks.add(
            NativeSearchRecord(
              id: '${tracks.length}',
              title: _unescape(fields[2]),
              artist: _unescape(fields[3]),
              album: _unescape(fields[4]),
              albumArtist: _optional(fields[5]),
              provider: _unescape(fields[6]),
            ),
          );
        case 'M':
          queries.add((
            _optional(fields[1]) ?? '',
            _optional(fields[2])?.split(' ').map(int.parse).toList() ??
                const <int>[],
          ));
        case 'T':
        case 'F':
          break;
        default:
          fail('unknown case kind ${fields[0]}');
      }
    }
    expect(queries, isNotEmpty, reason: 'no M cases read');

    final NativeSearchIndex index = NativeSearchIndex.build(tracks);
    addTearDown(index.dispose);
    for (final (String query, List<int> expected) in queries) {
      expect(index.matchPositions(query), expected,
          reason: 'matches for "$query"');
    }
  });
}
