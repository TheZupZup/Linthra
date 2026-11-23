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
    documentation = _read(
        p.join(root, 'docs', 'distribution', 'google-play', 'publishing.md'));
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

    // A manual dispatch can pass a `release_tag` that matches pubspec.yaml but
    // was never actually tagged, which still produces a tag-shaped bundle
    // name. The name alone is therefore not proof that a release exists.
    test('confirms the tag named by the bundle actually exists', () {
      // A tag ref specifically: the Commits API would also accept a branch
      // named like a version, which would prove nothing about a tag.
      expect(
        workflow,
        contains(r'gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/'),
      );
      expect(
        workflow,
        isNot(contains(r'gh api "repos/${GITHUB_REPOSITORY}/commits/')),
      );
      expect(workflow, contains('Refusing to publish an untagged build.'));
    });

    // The stable release workflow creates an annotated tag, whose ref points
    // at a tag object rather than the commit it names.
    test('dereferences annotated tags before comparing commits', () {
      expect(workflow, contains(r'[ "$tag_object_type" = "tag" ]'));
      expect(
        workflow,
        contains(r'gh api "repos/${GITHUB_REPOSITORY}/git/tags/'),
      );
    });

    // Android Release Build checks out its dispatch ref, never the tag, so a
    // build dispatched while the branch carried commits past the tag makes a
    // tag-named bundle whose code the tag does not name. Existing is not
    // enough; the tag has to point at the commit the build ran on.
    test('binds the bundle to the commit the tag names', () {
      expect(workflow,
          contains(r'SOURCE_SHA: ${{ github.event.workflow_run.head_sha }}'));
      expect(workflow, contains(r'[ "$tag_sha" != "$SOURCE_SHA" ]'));
      expect(
        workflow,
        contains('Refusing to publish code the tag does not name.'),
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

    // `read` stops at the first newline, so a value carrying one could hide an
    // entry behind it. The whole value is stripped of whitespace before being
    // split, and the upload action receives that same normalized value.
    test('strips whitespace before splitting, and ships what it checked', () {
      expect(workflow, contains("tr -d '[:space:]'"));
      expect(workflow, contains(r'<<< "$tracks"'));
      expect(workflow, contains(r'tracks: ${{ steps.config.outputs.tracks }}'));
      expect(
        workflow,
        isNot(contains(r'tracks: ${{ env.GOOGLE_PLAY_TRACK }}')),
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
