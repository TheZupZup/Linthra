import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/download_gate.dart';

/// Replays `test/fixtures/download_gate_cases.txt`, the cases the Rust gate
/// (native/linthra_core/src/download_gate_cases_test.rs) replays too.
void main() {
  test(
    ''
    'the download gate agrees with every shared case',
    () {
      final List<String> lines = File('test/fixtures/download_gate_cases.txt')
          .readAsLinesSync()
          .where((String line) => line.isNotEmpty && !line.startsWith('#'))
          .toList();

      for (final String line in lines) {
        final List<String> fields = line.split('\t');
        expect(fields, hasLength(3), reason: 'bad case line "$line"');
        expect(
          downloadGate(
            NetworkStatus.values.byName(fields[0]),
            allowMobileData: bool.parse(fields[1]),
          ),
          DownloadGate.values.byName(fields[2]),
          reason: 'case "$line"',
        );
      }
      // Every network status with the setting on and off.
      expect(lines, hasLength(8));
    },
  );
}
