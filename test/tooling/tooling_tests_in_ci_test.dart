import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Every Python test under test/tooling/ is run by some workflow.
///
/// CI runs them one `python3 test/tooling/<name>.py` step at a time, spread
/// over several workflows, and a test nothing runs passes forever: two of
/// them, guarding the Flatpak permissions check and scripts/verify_linux.sh,
/// had been run only by the local twin in scripts/verify_native.sh.
void main() {
  test('every test/tooling/*_test.py is run by a workflow', () {
    // Comments are left out: most steps name their local twin command in
    // one, and that must not count as the step running it.
    final String workflows = <String>[
      for (final FileSystemEntity entity
          in Directory('.github/workflows').listSync())
        if (entity is File && entity.path.endsWith('.yml'))
          for (final String line in entity.readAsLinesSync())
            if (!line.trimLeft().startsWith('#')) line,
    ].join('\n');
    final List<String> tests = <String>[
      for (final FileSystemEntity entity
          in Directory('test/tooling').listSync())
        if (entity is File && entity.path.endsWith('_test.py'))
          'test/tooling/${p.basename(entity.path)}',
    ]..sort();

    expect(tests, isNotEmpty);
    expect(
      <String>[
        for (final String test in tests)
          if (!workflows.contains('python3 $test')) test,
      ],
      isEmpty,
      reason: 'a tooling test no workflow runs never fails',
    );
  });
}
