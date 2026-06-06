import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/version_from_tag.dart';

/// F-Droid release-compatibility guardrails.
///
/// These tests do not exercise app behavior — they pin the *release plumbing*
/// that F-Droid depends on, so an innocent-looking edit to a CI workflow, the
/// Gradle config, `.gitignore`, or the F-Droid metadata can't silently break
/// the F-Droid build or the binaries it references. Each `group` maps to one
/// failure mode that the release docs warn about (see docs/release-process.md
/// and docs/fdroid-build-recipe.md):
///
///   1. versionCode encoding stays canonical and monotonic across the repo's
///      own files (pubspec.yaml, the Gradle per-ABI override, the F-Droid
///      metadata `VercodeOperation`).
///   2. The release asset names stay compatible with the F-Droid per-Build
///      `binary:` URLs (a rename in either place breaks the download).
///   3. `pubspec.lock` stays tracked / never re-ignored, so F-Droid resolves
///      the exact pinned dependency versions (reproducible builds).
///   4. fdroiddata `commit:` fields are full 40-character SHAs, not tag names.
///
/// They read files only. Nothing here bumps a version, tags, publishes, or
/// edits the external fdroiddata repo.
///
/// Sibling coverage: the encoder itself lives in tool/version_from_tag.dart and
/// is exercised by test/tooling/version_from_tag_test.dart; that pubspec.yaml's
/// versionCode is the canonical encoding of its versionName is asserted by
/// test/core/app_info_version_test.dart. This file complements those by pinning
/// the *cross-file* F-Droid relationships they don't cover.
void main() {
  final String root = _repoRoot();

  // The three ABIs F-Droid builds per release, in rank order. This single map
  // is the contract the Gradle override, the workflow asset names, and the
  // F-Droid metadata must all agree on; changing the ABI set is a deliberate
  // edit here plus the three files below.
  const Map<String, int> abiRanks = <String, int>{
    'armeabi-v7a': 1,
    'arm64-v8a': 2,
    'x86_64': 3,
  };

  late String pubspec;
  late String metadata;
  late String workflow;
  late String buildGradle;

  setUpAll(() {
    pubspec = _read(p.join(root, 'pubspec.yaml'));
    metadata =
        _read(p.join(root, 'metadata', 'io.github.thezupzup.linthra.yml'));
    workflow = _read(
        p.join(root, '.github', 'workflows', 'android-release-build.yml'));
    buildGradle = _read(p.join(root, 'android', 'app', 'build.gradle'));
  });

  group('versionCode encoding & monotonicity', () {
    test(
        'pubspec.yaml is not behind the last release recorded in F-Droid '
        'metadata (versionCode never goes backwards)', () {
      final _Version v = _parsePubspecVersion(pubspec);
      final String current = _single(
          metadata,
          RegExp(r'^CurrentVersion:\s*(\S+)', multiLine: true),
          'CurrentVersion');
      final int currentBase = versionFromTag(current).code;
      expect(
        v.code,
        greaterThanOrEqualTo(currentBase),
        reason: 'pubspec.yaml base versionCode (${v.code}, for ${v.name}) is '
            'behind the last F-Droid release ($current → $currentBase). '
            'Android/F-Droid require a strictly non-decreasing versionCode, so '
            'a release built from this pubspec would be rejected. Bump '
            'pubspec.yaml — see docs/release-process.md §1.',
      );
    });

    test('F-Droid metadata per-ABI versionCodes are base*10 + abiRank', () {
      final List<_AbiBuild> builds = _parseMetadataBuilds(metadata, abiRanks);
      expect(builds.map((_AbiBuild b) => b.abi).toSet(), abiRanks.keys.toSet(),
          reason: 'metadata Builds must cover exactly the F-Droid ABIs.');
      for (final _AbiBuild b in builds) {
        final int base = versionFromTag(b.versionName).code;
        final int expected = base * 10 + abiRanks[b.abi]!;
        expect(
          b.versionCode,
          expected,
          reason: 'metadata ${b.abi} build versionCode (${b.versionCode}) must '
              'equal base*10 + rank = $base*10 + ${abiRanks[b.abi]} = '
              '$expected. This is the same rule as '
              'android/app/build.gradle\'s versionCodeOverride and the '
              'VercodeOperation below; keep all three in lockstep.',
        );
      }
    });

    test('CurrentVersionCode is the canonical top per-ABI code', () {
      final String currentName = _single(
          metadata,
          RegExp(r'^CurrentVersion:\s*(\S+)', multiLine: true),
          'CurrentVersion');
      final int currentCode = int.parse(_single(
          metadata,
          RegExp(r'^CurrentVersionCode:\s*(\d+)', multiLine: true),
          'CurrentVersionCode'));
      final int base = versionFromTag(currentName).code;
      final int topRank =
          abiRanks.values.reduce((int a, int b) => a > b ? a : b);
      expect(
        currentCode,
        base * 10 + topRank,
        reason: 'CurrentVersionCode ($currentCode) must be the highest per-ABI '
            'code for CurrentVersion ($currentName): base*10 + $topRank = '
            '${base * 10 + topRank}.',
      );
    });

    test('Gradle per-ABI ranks match VercodeOperation and the canonical map',
        () {
      // android/app/build.gradle: def fdroidAbiCodes = ["armeabi-v7a": 1, ...]
      final Map<String, int> gradleRanks = <String, int>{};
      for (final RegExpMatch m in RegExp(r'"([\w-]+)":\s*(\d+)').allMatches(
          _single(buildGradle, RegExp(r'fdroidAbiCodes\s*=\s*(\[[^\]]*\])'),
              'fdroidAbiCodes'))) {
        gradleRanks[m.group(1)!] = int.parse(m.group(2)!);
      }
      expect(gradleRanks, abiRanks,
          reason: 'android/app/build.gradle fdroidAbiCodes drifted from the '
              'canonical ABI→rank map.');

      // The override multiplies the base code by 10 (base*10 + rank), exactly
      // like the metadata VercodeOperation entries.
      expect(buildGradle, contains('variant.versionCode * 10 + abiCode'),
          reason: 'The Gradle per-ABI override must stay `base*10 + abiRank`.');

      // metadata VercodeOperation: ["%c*10 + 1", "%c*10 + 2", "%c*10 + 3"].
      final List<int> opRanks = RegExp(r'%c\s*\*\s*10\s*\+\s*(\d+)')
          .allMatches(metadata)
          .map((RegExpMatch m) => int.parse(m.group(1)!))
          .toList();
      expect(opRanks.toSet(), abiRanks.values.toSet(),
          reason: 'metadata VercodeOperation ranks must match the per-ABI '
              'ranks used by Gradle (base*10 + rank).');
    });
  });

  group('release asset naming (F-Droid binary: compatibility)', () {
    // The exact filename shape F-Droid downloads per ABI. `%v` expands to the
    // build's versionName, so `v%v` == the release tag (`v` + versionName).
    final RegExp binaryUrl =
        RegExp(r'^https://github\.com/[^/]+/[^/]+/releases/download/v%v/'
            r'linthra-v%v-([A-Za-z0-9_-]+)-release-signed\.apk$');

    test('every metadata binary: URL has the canonical F-Droid shape', () {
      final List<String> urls =
          _all(metadata, RegExp(r'^\s*binary:\s*(\S+)', multiLine: true));
      expect(urls, isNotEmpty,
          reason: 'metadata must keep per-Build binary: URLs.');
      final Set<String> abis = <String>{};
      for (final String url in urls) {
        final RegExpMatch? m = binaryUrl.firstMatch(url);
        expect(m, isNotNull,
            reason: 'binary: URL "$url" must be '
                'https://github.com/<owner>/<repo>/releases/download/v%v/'
                'linthra-v%v-<abi>-release-signed.apk so F-Droid can fetch the '
                'upstream-signed APK. A rename here breaks the F-Droid build.');
        abis.add(m!.group(1)!);
      }
      expect(abis, abiRanks.keys.toSet(),
          reason: 'binary: URLs must cover exactly the F-Droid ABIs.');
    });

    test('the release workflow produces those exact asset names', () {
      // Universal APK/AAB stem: linthra-<tag>-release-signed (one ${var}).
      expect(
        RegExp(r'linthra-\$\{[A-Za-z_]+\}-release-signed').hasMatch(workflow),
        isTrue,
        reason: 'android-release-build.yml must name the universal asset '
            'linthra-<tag>-release-signed; this is what the F-Droid universal '
            'binary and the sideload URL expect.',
      );
      // Per-ABI stem: linthra-<tag>-<abi>-release-signed (two ${var}).
      expect(
        RegExp(r'linthra-\$\{[A-Za-z_]+\}-\$\{[A-Za-z_]+\}-release-signed')
            .hasMatch(workflow),
        isTrue,
        reason: 'android-release-build.yml must name per-ABI assets '
            'linthra-<tag>-<abi>-release-signed so they match the metadata '
            'binary: URLs (linthra-v%v-<abi>-release-signed.apk).',
      );
      // The per-ABI split is over exactly the canonical ABI list.
      expect(workflow, contains(abiRanks.keys.join(' ')),
          reason: 'android-release-build.yml must split per ABI over exactly '
              '"${abiRanks.keys.join(' ')}" so every metadata binary: URL has a '
              'matching uploaded asset.');
    });
  });

  group('pubspec.lock stays tracked (reproducible F-Droid builds)', () {
    test('pubspec.lock exists and is non-empty', () {
      final File lock = File(p.join(root, 'pubspec.lock'));
      expect(lock.existsSync(), isTrue,
          reason: 'pubspec.lock must be committed so F-Droid resolves the same '
              'pinned dependency versions. See docs/release-process.md.');
      expect(lock.lengthSync(), greaterThan(0));
    });

    test('.gitignore has no rule that would ignore pubspec.lock', () {
      // A cheap textual net that works even outside a git work tree. The
      // earlier "commit pubspec.lock" work (PR #139) must not get undone by a
      // stray ignore rule.
      for (final String path in <String>['.gitignore', 'android/.gitignore']) {
        final File f = File(p.join(root, path));
        if (!f.existsSync()) continue;
        for (final String raw in f.readAsLinesSync()) {
          final String line = raw.trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          expect(
            _ignoreRuleHitsPubspecLock(line),
            isFalse,
            reason: '$path line "$raw" would re-ignore pubspec.lock; it must '
                'stay tracked for reproducible F-Droid builds.',
          );
        }
      }
    });

    test('git agrees pubspec.lock is tracked and not ignored', () {
      if (!_inGitWorkTree(root)) {
        // Outside a git checkout (some sandboxes) the textual check above still
        // guards us; skip the authoritative git probe.
        return;
      }
      final ProcessResult tracked = Process.runSync(
          'git', <String>['ls-files', '--error-unmatch', 'pubspec.lock'],
          workingDirectory: root);
      expect(tracked.exitCode, 0,
          reason: 'git does not track pubspec.lock (it must be committed):\n'
              '${tracked.stderr}');
      // `git check-ignore` exits 0 if the path IS ignored, 1 if it is not.
      final ProcessResult ignored = Process.runSync(
          'git', <String>['check-ignore', 'pubspec.lock'],
          workingDirectory: root);
      expect(ignored.exitCode, 1,
          reason: 'pubspec.lock is matched by a git ignore rule '
              '("${ignored.stdout.toString().trim()}"); it must stay tracked.');
    });
  });

  group('fdroiddata commit: fields are full 40-char SHAs', () {
    test('every metadata commit: is a 40-hex-digit SHA, not a tag name', () {
      // docs/release-process.md: a manual fdroiddata Builds entry must pin the
      // full 40-character commit SHA behind the tag (git rev-list -n 1 <tag>),
      // never the tag name. (Format only — we deliberately do NOT resolve the
      // SHA against git here, because CI uses shallow clones that won't contain
      // older release commits.)
      final List<String> commits =
          _all(metadata, RegExp(r'^\s*commit:\s*(\S+)', multiLine: true));
      expect(commits, isNotEmpty,
          reason: 'metadata Builds must pin a commit: per entry.');
      final RegExp fullSha = RegExp(r'^[0-9a-f]{40}$');
      for (final String c in commits) {
        expect(
          fullSha.hasMatch(c),
          isTrue,
          reason: 'commit: "$c" must be a full 40-character lowercase hex SHA, '
              'not a tag name. Resolve it with `git rev-list -n 1 <tag>`. See '
              'docs/release-process.md.',
        );
      }
    });
  });
}

/// One `versionName`/`versionCode` pair parsed from pubspec.yaml.
class _Version {
  const _Version(this.name, this.code);
  final String name;
  final int code;
}

/// One per-ABI F-Droid Build entry (versionName + versionCode + ABI).
class _AbiBuild {
  const _AbiBuild(this.versionName, this.versionCode, this.abi);
  final String versionName;
  final int versionCode;
  final String abi;
}

_Version _parsePubspecVersion(String pubspec) {
  final RegExpMatch? m =
      RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
  if (m == null) fail('pubspec.yaml has no `version:` line');
  final String raw = m.group(1)!;
  final int plus = raw.indexOf('+');
  if (plus < 0) {
    fail('pubspec.yaml version "$raw" must be `<versionName>+<versionCode>`.');
  }
  final int? code = int.tryParse(raw.substring(plus + 1));
  if (code == null) {
    fail('pubspec.yaml versionCode in "$raw" is not an integer.');
  }
  return _Version(raw.substring(0, plus), code);
}

/// Parses the per-ABI Builds in order, pairing each `versionCode:`/`versionName:`
/// with the ABI read from its `output:` line and cross-checking the `binary:`
/// URL's ABI. Fails if the file's structure no longer lines up.
List<_AbiBuild> _parseMetadataBuilds(
    String metadata, Map<String, int> abiRanks) {
  // versionName is the first key of each YAML list item, so it carries the
  // `- ` dash; the other keys are plain indented sub-keys.
  final List<String> names =
      _all(metadata, RegExp(r'^\s*-?\s*versionName:\s*(\S+)', multiLine: true));
  final List<String> codes =
      _all(metadata, RegExp(r'^\s+versionCode:\s*(\d+)', multiLine: true));
  final List<String> outputs = _all(
      metadata,
      RegExp(r'^\s+output:\s*\S*app-([A-Za-z0-9_-]+)-release\.apk',
          multiLine: true));
  final List<String> binaries = _all(
      metadata,
      RegExp(
          r'^\s+binary:\s*\S*linthra-v%v-([A-Za-z0-9_-]+)-release-signed\.apk',
          multiLine: true));

  final int n = names.length;
  expect(<int>{codes.length, outputs.length, binaries.length}, <int>{n},
      reason: 'metadata Builds are malformed: found $n versionName, '
          '${codes.length} versionCode, ${outputs.length} output, '
          '${binaries.length} binary entries — they must align 1:1.');

  final List<_AbiBuild> builds = <_AbiBuild>[];
  for (int i = 0; i < n; i++) {
    expect(outputs[i], binaries[i],
        reason: 'metadata Build #$i output ABI (${outputs[i]}) and binary ABI '
            '(${binaries[i]}) disagree.');
    builds.add(_AbiBuild(names[i], int.parse(codes[i]), outputs[i]));
  }
  return builds;
}

/// Whether a single non-comment `.gitignore` rule would match `pubspec.lock`.
bool _ignoreRuleHitsPubspecLock(String rule) {
  final String r = rule.replaceFirst(RegExp(r'/$'), '');
  const List<String> hits = <String>[
    'pubspec.lock',
    '/pubspec.lock',
    '*.lock',
    '/*.lock',
    '**/pubspec.lock',
  ];
  return hits.contains(r);
}

String _single(String text, RegExp re, String label) {
  final RegExpMatch? m = re.firstMatch(text);
  if (m == null) fail('Could not find $label.');
  return m.group(1)!;
}

List<String> _all(String text, RegExp re) =>
    re.allMatches(text).map((RegExpMatch m) => m.group(1)!).toList();

bool _inGitWorkTree(String root) {
  try {
    final ProcessResult r = Process.runSync(
        'git', <String>['rev-parse', '--is-inside-work-tree'],
        workingDirectory: root);
    return r.exitCode == 0 && (r.stdout as String).trim() == 'true';
  } on ProcessException {
    return false;
  }
}

String _read(String path) {
  final File f = File(path);
  expect(f.existsSync(), isTrue, reason: 'Expected file is missing: $path');
  return f.readAsStringSync();
}

String _repoRoot() {
  Directory d = Directory.current;
  while (true) {
    if (File(p.join(d.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(d.path, 'metadata')).existsSync()) {
      return d.path;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    d = parent;
  }
}
