import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/services/track_end.dart';

/// Replays `test/fixtures/track_end_cases.txt`, the cases the Rust rule
/// (native/linthra_core/src/track_end_cases_test.rs) replays too.
void main() {
  for (final bool useNative in <bool>[false, true]) {
    test(
      '${useNative ? 'Rust' : 'Dart'}: a finished track moves on as every '
      'shared case says',
      skip:
          useNative && !LinthraCore.isAvailable ? 'Rust core not built' : false,
      () {
        final List<String> lines = File('test/fixtures/track_end_cases.txt')
            .readAsLinesSync()
            .where((String line) => line.isNotEmpty && !line.startsWith('#'))
            .toList();

        for (final String line in lines) {
          final List<String> fields = line.split('\t');
          expect(fields, hasLength(3), reason: 'bad case line "$line"');
          expect(
            trackEndAction(
              RepeatMode.values.byName(fields[0]),
              hasNext: bool.parse(fields[1]),
              useNative: useNative,
            ),
            TrackEndAction.values.byName(fields[2]),
            reason: 'case "$line"',
          );
        }
        // Every repeat mode, with and without a next track.
        expect(lines, hasLength(6));
      },
    );
  }
}
