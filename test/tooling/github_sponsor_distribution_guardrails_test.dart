import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final String root = _repoRoot();
  late String sponsorWorkflow;
  late String simulationWorkflow;
  late String canonicalWorkflow;

  setUpAll(() {
    sponsorWorkflow = _read(
      p.join(root, '.github', 'workflows', 'github-sponsor-apk.yml'),
    );
    simulationWorkflow = _read(
      p.join(root, '.github', 'workflows', 'github-sponsor-simulation-apk.yml'),
    );
    canonicalWorkflow = _read(
      p.join(root, '.github', 'workflows', 'android-release-build.yml'),
    );
  });

  group('GitHub Sponsor release distribution', () {
    test('official Sponsor APK uses real GitHub verification', () {
      expect(
        sponsorWorkflow,
        contains('--dart-define=LINTHRA_DISTRIBUTION=github'),
      );
      expect(
        sponsorWorkflow,
        contains('--dart-define=LINTHRA_GITHUB_OAUTH_CLIENT_ID='),
      );
      expect(
        sponsorWorkflow,
        isNot(contains('LINTHRA_GITHUB_SPONSOR_SIMULATION=')),
      );
    });

    test('canonical release assets never receive the Sponsor simulation flag',
        () {
      expect(
        canonicalWorkflow,
        isNot(contains('LINTHRA_GITHUB_SPONSOR_SIMULATION=')),
      );
    });
  });

  group('Sponsor simulation isolation', () {
    test('simulation workflow exercises both locked and unlocked states', () {
      expect(simulationWorkflow, contains('- locked'));
      expect(simulationWorkflow, contains('- unlocked'));
      expect(
        simulationWorkflow,
        contains(
          '--dart-define=LINTHRA_GITHUB_SPONSOR_SIMULATION='
          r'${{ matrix.state }}',
        ),
      );
    });

    test('simulation APK is deleted and never uploaded or released', () {
      expect(simulationWorkflow, contains('rm -f "\$apk"'));
      expect(simulationWorkflow, contains('test ! -f "\$apk"'));
      expect(simulationWorkflow, isNot(contains('actions/upload-artifact')));
      expect(simulationWorkflow, isNot(contains('gh release')));
      expect(simulationWorkflow, isNot(contains('release upload')));
    });
  });
}

String _read(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue, reason: 'Expected file is missing: $path');
  return file.readAsStringSync();
}

String _repoRoot() {
  Directory directory = Directory.current;
  while (true) {
    if (File(p.join(directory.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(directory.path, 'metadata')).existsSync()) {
      return directory.path;
    }

    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    directory = parent;
  }
}
