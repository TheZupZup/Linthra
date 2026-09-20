import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Toolchain pin guardrails.
///
/// Linthra pins its build toolchain in four files, and those files are the only
/// place a version number is allowed to live:
///
///   * `.flutter-version` .............................. Flutter SDK
///   * `.java-version` ................................. JDK
///   * `android/gradle/wrapper/gradle-wrapper.properties` Gradle
///   * `android/settings.gradle` ....................... AGP + Kotlin plugin
///
/// Everything else — CI workflows, scripts, docs — must either read those files
/// or, where prose has to name a version, name the *pinned* one. Before this
/// suite existed the Flutter version was copied into seven workflows, two
/// workflow comments still advertised a three-years-stale AGP/Gradle/Kotlin
/// trio, and the docs promised a JDK that CI does not install. That drift is
/// exactly what breaks a reproducible F-Droid build, so it is now a test
/// failure instead of a surprise at release time.
///
/// These tests read files only. Nothing here upgrades a toolchain.
///
/// Sibling coverage: test/tooling/fdroid_release_guardrails_test.dart pins the
/// release plumbing (versionCodes, asset names, `pubspec.lock`); this file pins
/// the toolchain versions those releases are built with.
void main() {
  final String root = _repoRoot();

  // The pins, read from the files that own them.
  late final String flutterPin = _readPin(root, '.flutter-version');
  late final String javaPin = _readPin(root, '.java-version');
  late final String gradlePin = _match(
    _read(root,
        p.join('android', 'gradle', 'wrapper', 'gradle-wrapper.properties')),
    RegExp(r'distributionUrl=.*?gradle-([0-9][0-9.]*)-'),
    'the Gradle distribution version in gradle-wrapper.properties',
  );
  late final String settingsGradle =
      _read(root, p.join('android', 'settings.gradle'));
  late final String agpPin = _match(
    settingsGradle,
    RegExp(r'id\s+"com\.android\.application"\s+version\s+"([^"]+)"'),
    'the AGP version in android/settings.gradle',
  );
  late final String kotlinPin = _match(
    settingsGradle,
    RegExp(r'id\s+"org\.jetbrains\.kotlin\.android"\s+version\s+"([^"]+)"'),
    'the Kotlin plugin version in android/settings.gradle',
  );

  group('the pin files are the source of truth', () {
    test('.flutter-version holds one bare stable version', () {
      expect(flutterPin, matches(RegExp(r'^\d+\.\d+\.\d+$')),
          reason: '.flutter-version must hold exactly the stable Flutter '
              'version (e.g. 3.44.7) — scripts/setup_flutter.sh, '
              'scripts/doctor.sh, the F-Droid recipe and '
              '.github/actions/setup-flutter all read it verbatim.');
    });

    test('.java-version holds one bare JDK version', () {
      expect(javaPin, matches(RegExp(r'^\d+(\.\d+)*$')),
          reason: '.java-version must hold exactly the JDK version '
              'actions/setup-java should install (e.g. 17). It is the single '
              'source of truth for the JDK — see docs/development.md.');
    });

    test('Gradle, AGP and Kotlin are pinned to exact versions', () {
      for (final MapEntry<String, String> pin in <String, String>{
        'Gradle': gradlePin,
        'AGP': agpPin,
        'Kotlin': kotlinPin,
      }.entries) {
        expect(pin.value, matches(RegExp(r'^\d+\.\d+\.\d+$')),
            reason: '${pin.key} must be pinned to an exact version, not a '
                'range or a "+" wildcard — the F-Droid build resolves it '
                'offline from these files.');
      }
    });
  });

  group('workflows read the pins instead of repeating them', () {
    test('no workflow hardcodes the Flutter version', () {
      for (final _RepoFile f in _workflowFiles(root)) {
        expect(
          f.text.contains(flutterPin),
          isFalse,
          reason: '${f.path} names the Flutter version ($flutterPin) directly. '
              'Use `uses: ./.github/actions/setup-flutter`, which reads '
              '.flutter-version, so a bump stays a one-line edit.',
        );
      }
    });

    test('every flutter-version input is an expression, not a literal', () {
      // The shared action is the one place allowed to pass the input at all,
      // and it passes the value it read from .flutter-version.
      for (final _RepoFile f in _actionFiles(root)) {
        for (final String value in _all(
            f.text, RegExp(r'^\s*flutter-version:\s*(.+)$', multiLine: true))) {
          expect(
            value.trim().startsWith(r'${{'),
            isTrue,
            reason: '${f.path} passes flutter-version: $value. Only '
                '.github/actions/setup-flutter may set this input, and only '
                'from the .flutter-version file.',
          );
        }
      }
    });

    test('the shared action installs the version it read from the pin file',
        () {
      final String action = _read(
          root, p.join('.github', 'actions', 'setup-flutter', 'action.yml'));
      expect(action, contains('.flutter-version'),
          reason: 'The setup-flutter action must read .flutter-version.');
      expect(action,
          contains(r'flutter-version: ${{ steps.pin.outputs.version }}'),
          reason: 'The setup-flutter action must install the version it read '
              'from .flutter-version.');
    });

    test('every workflow that runs Flutter sets it up from the pin', () {
      final RegExp runsFlutter =
          RegExp(r'\bflutter\s+(pub|test|analyze|build|doctor)\b');
      for (final _RepoFile f in _workflowFiles(root)) {
        if (!runsFlutter.hasMatch(f.text)) continue;
        expect(
          f.text,
          contains('uses: ./.github/actions/setup-flutter'),
          reason: '${f.path} runs Flutter but does not install it through '
              '.github/actions/setup-flutter, so it could run against a '
              'different SDK than the rest of CI.',
        );
      }
    });

    test('no workflow hardcodes the JDK version', () {
      for (final _RepoFile f in _workflowFiles(root)) {
        final List<String> literals =
            _all(f.text, RegExp(r'^\s*java-version:\s*(.+)$', multiLine: true));
        expect(
          literals,
          isEmpty,
          reason: '${f.path} sets java-version: ${literals.join(', ')}. Use '
              '`java-version-file: .java-version` so the JDK has one source of '
              'truth.',
        );
      }
    });

    test('every setup-java step reads .java-version', () {
      for (final _RepoFile f in _workflowFiles(root)) {
        final int steps = 'uses: actions/setup-java@'.allMatches(f.text).length;
        if (steps == 0) continue;
        expect(
          'java-version-file: .java-version'.allMatches(f.text).length,
          steps,
          reason: '${f.path} has $steps setup-java step(s) but not the same '
              'number of `java-version-file: .java-version` inputs.',
        );
      }
    });
  });

  group('shared GitHub Actions are pinned consistently', () {
    test('each third-party action is used at one ref across .github/', () {
      // actions/checkout was on @v4 in eleven workflows and @v5 in the CI
      // fixer; a split like that makes "what does CI actually run" a per-file
      // question and makes future Dependabot PRs noisy.
      final Map<String, Set<String>> refs = <String, Set<String>>{};
      final Map<String, Set<String>> users = <String, Set<String>>{};
      for (final _RepoFile f in <_RepoFile>[
        ..._workflowFiles(root),
        ..._actionFiles(root),
      ]) {
        for (final RegExpMatch m
            in RegExp(r'uses:\s*([\w.-]+/[\w.-]+)@([\w.-]+)')
                .allMatches(f.text)) {
          refs.putIfAbsent(m.group(1)!, () => <String>{}).add(m.group(2)!);
          users.putIfAbsent(m.group(1)!, () => <String>{}).add(f.path);
        }
      }
      refs.forEach((String action, Set<String> pinned) {
        expect(
          pinned,
          hasLength(1),
          reason: '$action is pinned to ${pinned.join(' and ')} across '
              '${users[action]!.join(', ')}. Keep one ref per action.',
        );
      });
    });
  });

  group('docs and comments cannot drift from the pins', () {
    // Prose is allowed to name a version; it just has to name the pinned one.
    // Each rule is keyword-anchored so package versions and Dart/SDK numbers
    // nearby are left alone.
    test('every Flutter version mentioned is the pinned one', () {
      _expectMentions(
        root,
        RegExp(r'\bflutter\s+(?:SDK\s+)?v?(\d+\.\d+\.(?:\d+|x))\b',
            caseSensitive: false),
        flutterPin,
        'Flutter',
      );
    });

    test('every Gradle version mentioned is the pinned one', () {
      _expectMentions(
        root,
        RegExp(r'\bgradle[\s-]+v?(\d+\.\d+(?:\.\d+)?)\b', caseSensitive: false),
        gradlePin,
        'Gradle',
      );
    });

    test('every AGP version mentioned is the pinned one', () {
      _expectMentions(
        root,
        RegExp(
            r'\b(?:AGP|android\s+gradle\s+plugin)\s+v?(\d+\.\d+(?:\.\d+)?)\b',
            caseSensitive: false),
        agpPin,
        'AGP',
      );
    });

    test('every Kotlin version mentioned is the pinned one', () {
      _expectMentions(
        root,
        RegExp(r'\bkotlin(?:\s+gradle\s+plugin)?\s+v?(\d+\.\d+(?:\.\d+)?)\b',
            caseSensitive: false),
        kotlinPin,
        'Kotlin',
      );
    });

    test('every JDK version mentioned is the pinned one', () {
      _expectMentions(
        root,
        RegExp(r'\b(?:JDK|Java)\s+\(?(\d+)\)?\b'),
        javaPin,
        'JDK',
      );
    });
  });
}

/// Files that may name a toolchain version in prose or comments.
const List<String> _scannedDirs = <String>['docs', 'scripts', '.github'];

/// Versions a file is allowed to name because it is describing *history*, not
/// the current pin: dated investigation notes and audits keep naming the
/// toolchain they were run against. Anything not listed here must match the
/// pin — including the current-toolchain sentences in these same files.
const Map<String, Set<String>> _historicalVersions = <String, Set<String>>{
  'docs/fdroid-reproducibility-arm64.md': <String>{'3.27.4', '8.2.1'},
  'docs/fdroid-readiness.md': <String>{'3.27.4'},
  'docs/dependency-license-audit.md': <String>{'3.27.4'},
  // Names the Flutter 3.44.7 bump as the worked example of an upgrade that
  // needed application changes, which is why the Dart dependency updater is
  // allowed to open red PRs. That sentence is about that past upgrade, so it
  // keeps naming 3.44.7 after the pin moves on.
  'docs/dependency-updates.md': <String>{'3.44.7'},
};

/// Asserts every `pattern` match across the scanned files captures [pin].
///
/// A `3.44.x`-style mention is compared on its major.minor only, so docs may
/// legitimately refer to the stable line rather than the patch.
void _expectMentions(String root, RegExp pattern, String pin, String label) {
  for (final _RepoFile f in _scannedFiles(root)) {
    final Set<String> historical =
        _historicalVersions[f.path] ?? const <String>{};
    for (final RegExpMatch m in pattern.allMatches(_plain(f.text))) {
      final String found = m.group(1)!;
      if (historical.contains(found)) continue;
      final bool line = found.endsWith('.x');
      final String expected = line
          ? pin.split('.').take(found.split('.').length - 1).join('.')
          : pin;
      final String actual = line ? found.substring(0, found.length - 2) : found;
      expect(
        actual,
        expected,
        reason:
            '${f.path} says "${m.group(0)!.trim()}" but $label is pinned to '
            '$pin. Update the text, or — if the mention is deliberately '
            'historical — add it to _historicalVersions in '
            'test/tooling/toolchain_pins_test.dart.',
      );
    }
  }
}

/// Strips Markdown emphasis/code ticks and turns table pipes into spaces, so a
/// `| Kotlin Gradle plugin | **2.2.21** |` row reads like plain prose.
String _plain(String text) =>
    text.replaceAll(RegExp(r'[`*]'), '').replaceAll('|', ' ');

class _RepoFile {
  const _RepoFile(this.path, this.text);

  /// Repo-relative path, always with `/` separators.
  final String path;
  final String text;
}

List<_RepoFile> _workflowFiles(String root) => _filesUnder(
    root, p.join('.github', 'workflows'), <String>['.yml', '.yaml']);

List<_RepoFile> _actionFiles(String root) =>
    _filesUnder(root, p.join('.github', 'actions'), <String>['.yml', '.yaml']);

/// Every file that could name a toolchain version, minus the release notes —
/// those are immutable records of what shipped, not statements about today.
List<_RepoFile> _scannedFiles(String root) {
  final List<_RepoFile> files = <_RepoFile>[
    for (final String name in <String>['README.md', 'CONTRIBUTING.md'])
      if (File(p.join(root, name)).existsSync())
        _RepoFile(name, File(p.join(root, name)).readAsStringSync()),
    for (final String dir in _scannedDirs)
      ..._filesUnder(root, dir, <String>['.md', '.yml', '.yaml', '.sh']),
  ];
  return files
      .where((_RepoFile f) => !f.path.startsWith('docs/release-notes/'))
      .toList();
}

List<_RepoFile> _filesUnder(
    String root, String relativeDir, List<String> extensions) {
  final Directory dir = Directory(p.join(root, relativeDir));
  if (!dir.existsSync()) return const <_RepoFile>[];
  final List<_RepoFile> files = <_RepoFile>[
    for (final FileSystemEntity e in dir.listSync(recursive: true))
      if (e is File && extensions.contains(p.extension(e.path)))
        _RepoFile(
          p.split(p.relative(e.path, from: root)).join('/'),
          e.readAsStringSync(),
        ),
  ];
  files.sort((_RepoFile a, _RepoFile b) => a.path.compareTo(b.path));
  return files;
}

String _readPin(String root, String name) {
  final File f = File(p.join(root, name));
  expect(f.existsSync(), isTrue,
      reason: '$name is missing; it is a toolchain source of truth.');
  return f.readAsStringSync().trim();
}

String _read(String root, String relativePath) {
  final File f = File(p.join(root, relativePath));
  expect(f.existsSync(), isTrue,
      reason: 'Expected file is missing: $relativePath');
  return f.readAsStringSync();
}

String _match(String text, RegExp re, String label) {
  final RegExpMatch? m = re.firstMatch(text);
  if (m == null) fail('Could not read $label.');
  return m.group(1)!;
}

List<String> _all(String text, RegExp re) =>
    re.allMatches(text).map((RegExpMatch m) => m.group(1)!).toList();

String _repoRoot() {
  Directory d = Directory.current;
  while (true) {
    if (File(p.join(d.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(d.path, '.github')).existsSync()) {
      return d.path;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) {
      fail('Could not find repo root from ${Directory.current.path}');
    }
    d = parent;
  }
}
