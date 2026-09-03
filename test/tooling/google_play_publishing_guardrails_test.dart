import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final String root = _repoRoot();
  late String workflow;
  late String documentation;

  setUpAll(() {
    workflow = _read(
      p.join(root, '.github', 'workflows', 'google-play-closed-testing.yml'),
    );
    documentation = _read(p.join(root, 'docs', 'google-play-publishing.md'));
  });

  group('Google Play publisher trigger', () {
    test('reuses the Android release build instead of rebuilding Linthra', () {
      expect(workflow, contains('workflow_run:'));
      expect(workflow, contains('Android Release Build'));
      expect(workflow, isNot(contains('flutter build')));
      expect(workflow, contains('linthra-release-signed-aab'));
    });

    test('only considers successful upstream runs', () {
      expect(
        workflow,
        contains("github.event.workflow_run.conclusion == 'success'"),
      );
    });

    // The stable-release workflow starts the signed Android build with
    // `gh workflow run`, so its upstream run reports `workflow_dispatch`.
    // Accepting only `push` would skip every stable release.
    test('accepts both pushed tags and dispatched release builds', () {
      expect(workflow, contains("github.event.workflow_run.event == 'push'"));
      expect(
        workflow,
        contains("github.event.workflow_run.event == 'workflow_dispatch'"),
      );
    });

    test('auto-publishes tagged releases only, never ad-hoc manual builds', () {
      expect(workflow, contains('linthra-v*-release-signed.aab)'));
      expect(workflow, contains('publish=false'));
      expect(workflow, contains('publish=true'));
      expect(
        workflow,
        contains("steps.bundle.outputs.publish == 'true'"),
      );
    });

    test('keeps repository permissions read-only', () {
      expect(workflow, contains('actions: read'));
      expect(workflow, contains('contents: read'));
      expect(workflow, isNot(contains('contents: write')));
      expect(workflow, isNot(contains('actions: write')));
    });
  });

  group('Google Play publisher identity and credentials', () {
    test('pins the permanent Linthra Android package name', () {
      expect(
        workflow,
        contains('GOOGLE_PLAY_PACKAGE_NAME: io.github.thezupzup.linthra'),
      );
    });

    test('reads credentials only from the expected Actions secret', () {
      expect(
        workflow,
        contains(r'secrets.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON'),
      );
      expect(
        documentation,
        contains('GOOGLE_PLAY_SERVICE_ACCOUNT_JSON'),
      );
    });

    test('takes the testing track from a repository variable', () {
      expect(workflow, contains(r'vars.GOOGLE_PLAY_TRACK'));
      expect(documentation, contains('GOOGLE_PLAY_TRACK'));
    });
  });

  group('Google Play publisher safety', () {
    test('never accepts production as an automatic target', () {
      expect(workflow, contains(r'[ "$requested" = "production" ]'));
      expect(
        workflow,
        contains('Automatic production publishing is intentionally disabled.'),
      );
      expect(documentation, contains('Do **not** set it to `production`'));
    });

    // The pinned action's `tracks` input is plural, so a value like
    // "internal,production" must not slip past an exact-string comparison.
    test('rejects production inside a multi-track value', () {
      expect(workflow, contains("IFS=',' read -ra requested_tracks"));
      expect(
        workflow,
        contains(r'for requested in "${requested_tracks[@]}"'),
      );
      expect(
        workflow,
        isNot(contains(r'[ "$GOOGLE_PLAY_TRACK" = "production" ]')),
      );
    });

    test('requires the release-signed AAB artifact', () {
      expect(
        workflow,
        contains('select(.name == "linthra-release-signed-aab"'),
      );
      expect(
        workflow,
        contains('Expected exactly one linthra-release-signed-aab artifact'),
      );
      expect(workflow, isNot(contains('linthra-debug-signed-aab')));
    });

    test('skips cleanly until Google Play is connected', () {
      expect(
        workflow,
        contains('Google Play publishing is not connected yet'),
      );
      expect(
        documentation,
        contains('missing service-account secret → skip with a notice'),
      );
    });
  });

  group('Google Play upload action contract', () {
    const String pinnedUploadAction =
        'r0adkll/upload-google-play@e738b9dd8f2476ea806d921b64aacd24f34515a5';

    test('pins the reviewed upload action commit', () {
      expect(workflow, contains(pinnedUploadAction));
      expect(workflow, isNot(contains('r0adkll/upload-google-play@v1')));
    });

    test('uses the current plural release and track inputs', () {
      expect(workflow, contains('releaseFiles:'));
      expect(workflow, contains('tracks:'));
      expect(workflow, isNot(contains('\n          releaseFile:')));
      expect(workflow, isNot(contains('\n          track:')));
    });

    test('publishes testing releases as completed', () {
      expect(workflow, contains('status: completed'));
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
