import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/track_availability.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/sources/source_availability.dart';

/// Replays `test/fixtures/track_availability_cases.txt`, the cases the Rust
/// rule (native/linthra_core/src/track_availability_cases_test.rs) replays
/// too.
void main() {
  for (final bool useNative in <bool>[false, true]) {
    test(
      '${useNative ? 'Rust' : 'Dart'}: a row reports its availability as '
      'every shared case says',
      skip:
          useNative && !LinthraCore.isAvailable ? 'Rust core not built' : false,
      () {
        final List<String> lines =
            File('test/fixtures/track_availability_cases.txt')
                .readAsLinesSync()
                .where(
                  (String line) => line.isNotEmpty && !line.startsWith('#'),
                )
                .toList();

        for (final String line in lines) {
          final List<String> fields = line.split('\t');
          expect(fields, hasLength(5), reason: 'bad case line "$line"');
          expect(
            resolveTrackAvailability(
              isRemote: bool.parse(fields[0]),
              hasOfflineCopy: bool.parse(fields[1]),
              isExplicitDownload: bool.parse(fields[2]),
              availability: SourceAvailability.values.byName(fields[3]),
              useNative: useNative,
            ),
            TrackAvailabilityStatus.values.byName(fields[4]),
            reason: 'case "$line"',
          );
        }
        // Every combination of the three flags and the five availabilities.
        expect(lines, hasLength(40));
      },
    );
  }

  test('the shared cases name every value of both enums', () {
    final String cases =
        File('test/fixtures/track_availability_cases.txt').readAsStringSync();
    for (final Enum value in <Enum>[
      ...SourceAvailability.values,
      ...TrackAvailabilityStatus.values,
    ]) {
      expect(cases, contains(value.name), reason: value.name);
    }
  });
}
