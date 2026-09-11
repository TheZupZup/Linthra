import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String workflow;
  late String publish;

  setUpAll(() {
    workflow = File(
      '.github/workflows/flatpak-build.yml',
    ).readAsStringSync();
    publish = File(
      '.github/workflows/publish-stable-release.yml',
    ).readAsStringSync();
  });

  // The workflow gained a release path (#618), so "no write permission
  // anywhere" is no longer the right shape of this guard. What has to stay
  // true is that the elevation exists exactly once and belongs to the job that
  // only exists for a validated release tag — never to the build job every
  // fork PR runs.
  test('Flatpak CI stays read-only and fork-safe', () {
    expect(workflow, contains('permissions:\n  contents: read'));
    expect(workflow, isNot(contains(r'secrets.')));
    // The permission line itself, at job indentation — prose about it in the
    // comments above is not an elevation.
    expect('\n      contents: write\n'.allMatches(workflow).length, 1);
    expect(
      workflow,
      contains(
        "    if: \${{ needs.build-flatpak.outputs.is_release_build == 'true' }}\n"
        '    runs-on: ubuntu-24.04\n'
        '    permissions:\n'
        '      contents: write',
      ),
      reason: 'only the gated release packaging job may write to a Release',
    );
  });

  test('Flatpak CI does not depend on a restored build cache', () {
    expect(workflow, isNot(contains('actions/cache@')));
    expect(workflow, contains('--disable-cache'));
    expect(workflow, contains('--force-clean'));
  });

  // A single bad response from a source host used to fail the whole run: main
  // died on libplacebo when code.videolan.org answered the archive request
  // with an error page and the sha256 did not match. The prefetch retries the
  // downloads without becoming a gate of its own — it must never fail the job,
  // so the build step stays the one place a real source problem is reported.
  test('Flatpak CI retries source downloads without gating on them', () {
    expect(workflow, contains('--download-only'));
    expect(workflow, contains('for attempt in 1 2 3; do'));
    expect(
      workflow,
      contains(
        'echo "::warning::Prefetch did not complete; '
        'the build step downloads the rest."',
      ),
      reason: 'a failed prefetch must warn and carry on, not fail the job',
    );
  });

  test(
    'Flatpak CI installs manifest dependencies and builds the real package',
    () {
      expect(workflow, contains('--install-deps-from=flathub'));
      expect(workflow, contains('--install-deps-only'));
      expect(workflow, contains('--repo=repo-ci'));
      expect(workflow, contains('io.github.thezupzup.linthra.yml'));
      expect(workflow, contains('flatpak build-update-repo repo-ci'));
    },
  );

  // The job installs its host tools with --no-install-recommends, so anything a
  // dependency merely recommends has to be named explicitly. elfutils is the
  // one that bit: flatpak-builder only recommends it, and without its `eu-strip`
  // the build dies on the first native module, long before Linthra is reached.
  test('Flatpak CI installs the host tools the build and smoke need', () {
    for (final String package in <String>[
      // appstreamcli, for the metainfo validation step.
      'appstream',
      // desktop-file-validate, for the desktop entry.
      'desktop-file-utils',
      // eu-strip / eu-elfcompress, which flatpak-builder uses to split debug
      // symbols out of every module it builds.
      'elfutils',
      'flatpak-builder',
      // The gdk-pixbuf SVG loader, without which the appstreamcli compose that
      // flatpak-builder runs at finish time cannot read the scalable app icon.
      'librsvg2-common',
      // ostree, which unpacks a built .flatpak bundle so its contents can be
      // checked before it is attached to a Release.
      'ostree',
      // xwininfo and xprop, which the launch smoke reads window identity with.
      'x11-utils',
      // The headless display and session bus the smoke launches into.
      'xvfb',
      'dbus-x11',
    ]) {
      // Either a continuation line or the last entry of the list.
      expect(
        workflow,
        anyOf(
          contains('            $package \\\n'),
          contains('            $package\n'),
        ),
        reason: 'Missing host package: $package',
      );
    }
  });

  test('packaging-relevant changes trigger the workflow', () {
    for (final String path in <String>[
      "'flatpak/**'",
      "'linux/packaging/**'",
      "'linux/CMakeLists.txt'",
      "'linux/runner/**'",
      "'pubspec.lock'",
      "'.flutter-version'",
      "'third_party/**'",
      "'tool/branding/linthra_icon.svg'",
      // The release-bundle tooling is packaging too: a change to how a bundle
      // is named or checked must run the build that produces one.
      "'scripts/flatpak_bundle.py'",
      "'test/tooling/flatpak_bundle_test.py'",
    ]) {
      expect(workflow, contains(path), reason: 'Missing trigger path: $path');
    }
  });

  // #618. Everything below is the release path: the bundle a Linux user
  // downloads from a GitHub Release instead of extracting the native tarball.

  // A tag reaches a file name and a public upload, so it is validated for
  // shape *and* for the Release actually existing before anything is built —
  // the same two checks, in the same order, as linux-desktop-build.yml.
  test('a release build only runs for a validated, existing release tag', () {
    expect(workflow, contains('      release_tag:'));
    expect(
      workflow,
      contains(r'^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'),
    );
    expect(workflow, contains(r'gh release view "$RELEASE_TAG_INPUT"'));
    expect(workflow, contains(r'ref: ${{ steps.resolve.outputs.ref }}'));
  });

  // The whole point of the tag input: the bundle on the Release is built from
  // the released commit, not from whatever main happens to be at dispatch
  // time. A release build that disagrees with the repository's own version
  // bookkeeping fails before a version number reaches an artifact name.
  test('a release build verifies the release metadata at the tag', () {
    expect(
        workflow, contains(r'./scripts/release_preflight.sh "$RELEASE_TAG"'));
    expect(
      workflow,
      contains(r'check_release_metadata_sync.py --tag "$RELEASE_TAG"'),
    );
  });

  // The bundle is exported from the repository this same job built, launched
  // and verified — never rebuilt — so the artifact cannot drift from what was
  // tested. Its name comes from the shared helper, not from the workflow.
  test('the bundle is exported from the repository this job built', () {
    expect(workflow, contains('flatpak build-bundle'));
    expect(
      workflow,
      contains('            repo-ci \\\n'),
      reason: 'the bundle must be exported from the repository just built',
    );
    expect(workflow, contains('flatpak_bundle.py name'));
    expect(
      workflow,
      contains(
        '--runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo',
      ),
      reason: 'installing the bundle must be able to fetch the runtime',
    );
  });

  // The artifact itself is installed and launched the way a user installs it,
  // rather than only the repository it came from.
  test('the standalone bundle is installed and launched', () {
    expect(
      workflow,
      contains(r'bash ../scripts/flatpak_launch_smoke.sh "$BUNDLE_NAME"'),
    );
  });

  // The Release is already public by the time the bundle is uploaded, so an
  // artifact that fails a check must never become downloadable from it.
  test('the bundle is verified before it is attached to the Release', () {
    // The packaging job's own invocations, which run on the downloaded copy —
    // not the build job's earlier fail-fast check, and not the path filters.
    final int contents = workflow.indexOf(
      '.release-tooling/scripts/flatpak_bundle.py verify',
    );
    final int containment = workflow.indexOf(
      '.release-tooling/scripts/verify_release_containment.py',
    );
    final int upload = workflow.indexOf('gh release upload');

    expect(contents, greaterThan(-1));
    expect(containment, greaterThan(contents));
    expect(upload, greaterThan(containment));
  });

  // A dispatched run shares github.ref (main) with every push to main, so
  // without its own group a merge landing mid-release would cancel the build
  // the Release is waiting for.
  test('a release build is not cancelled by an unrelated push to main', () {
    expect(workflow, contains(r'flatpak-build-${{ inputs.release_tag ||'));
    expect(
        workflow, contains(r'cancel-in-progress: ${{ !inputs.release_tag }}'));
  });

  group('stable publication', () {
    test('dispatches the Flatpak build at the tag and waits for it', () {
      expect(publish, contains('gh workflow run flatpak-build.yml'));
      expect(publish, contains(r'-f release_tag="$RELEASE_TAG"'));
      expect(
        publish,
        contains(r'RUN_ID: ${{ steps.dispatch-flatpak.outputs.run_id }}'),
      );
      expect(publish, contains('--exit-status'));
    });

    // A stable Release must never be reported published and verified with the
    // Flatpak bundle missing, and its name must come from the same helper the
    // build used rather than a second spelling of the version.
    test('requires the bundle among the published assets', () {
      expect(publish, contains('scripts/flatpak_bundle.py name'));
      expect(publish, contains(r'"$flatpak_bundle"'));
    });

    // The bundle goes through the same artifact verification as every other
    // asset, so its SHA-256 lands in the same release record.
    test('verifies the published bundle alongside the other assets', () {
      expect(publish, contains(r'"$assets"/*.flatpak'));
    });
  });
}
