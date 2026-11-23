import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const String _docPath = 'docs/distribution/flatpak/flathub-update-process.md';

/// Keeps [docs/distribution/flatpak/flathub-update-process.md] honest (#453).
///
/// The doc's whole value is that a maintainer can follow it command by command
/// on the day of a release. That makes it exactly the kind of file that rots
/// silently: rename a script, move a doc, and the walkthrough still reads fine
/// while telling someone to run something that no longer exists. So every path
/// it names is checked to exist, and the pages that should point at it are
/// checked to still do so.
void main() {
  late String doc;

  setUpAll(() {
    doc = File(_docPath).readAsStringSync();
  });

  test('every repository path the walkthrough names exists', () {
    final Iterable<RegExpMatch> matches = RegExp(
      r'(?:scripts|test/tooling|linux/packaging|flatpak)/[\w./-]*[\w]',
    ).allMatches(doc);
    expect(matches, isNotEmpty);

    final Set<String> missing = <String>{};
    for (final RegExpMatch match in matches) {
      final String path = match.group(0)!;
      // Build outputs the walkthrough creates as it goes, not committed files.
      if (path.startsWith('flatpak/repo-ci') ||
          path.startsWith('flatpak/flatpak-builder-ci')) {
        continue;
      }
      if (!File(path).existsSync() && !Directory(path).existsSync()) {
        missing.add(path);
      }
    }
    expect(missing, isEmpty, reason: 'named but not in the repository');
  });

  test('every relative link resolves', () {
    final Set<String> broken = <String>{};
    for (final RegExpMatch match
        in RegExp(r'\]\(([^)#:\s]+)(?:#[^)]*)?\)').allMatches(doc)) {
      final String target = match.group(1)!;
      // Relative to the doc's own folder, as GitHub resolves it.
      final String resolved = p.normalize(p.join(p.dirname(_docPath), target));
      if (!File(resolved).existsSync() && !Directory(resolved).existsSync()) {
        broken.add(target);
      }
    }
    expect(broken, isEmpty);
  });

  test('the release process hands off to it', () {
    expect(
      File('docs/distribution/release-process.md').readAsStringSync(),
      contains('flathub-update-process.md'),
    );
  });

  test('it is discoverable from the docs index and the packaging README', () {
    expect(
      File('docs/README.md').readAsStringSync(),
      contains('flathub-update-process.md'),
    );
    expect(
      File('flatpak/README.md').readAsStringSync(),
      contains('flathub-update-process.md'),
    );
  });

  test('it names the version-sync tooling the release depends on', () {
    // #453 asks for the #452 tooling to be referenced rather than re-explained.
    expect(doc, contains('scripts/prepare_release_bump.py'));
    expect(doc, contains('scripts/check_release_metadata_sync.py'));
  });

  test('it stays honest that nothing is auto-merged or auto-pushed', () {
    expect(doc, contains('Nothing here is auto-merged'));
    expect(doc, contains('No credentials from this repository are involved'));
  });
}
