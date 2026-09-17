import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// No Dart code branches on *which* Linux desktop is running (#458).
///
/// Linthra's Linux integrations are all desktop standards: xdg-desktop-portal
/// for the file chooser and notifications, MPRIS on the session bus for media
/// controls and media keys, the freedesktop Secret Service for credentials,
/// freedesktop window properties for identity, and Flutter's own GTK embedder
/// (portal first) for the system light/dark preference. Every one of those is
/// answered by GNOME and by KDE Plasma, so nothing in `lib/` needs to know
/// which is on the other end.
///
/// A shortcut that *does* know is never a build failure and never a test
/// failure. It only means the untested desktop is the one that breaks after
/// release, which is what the compatibility matrix
/// (`docs/desktop-compatibility-matrix.md`) exists to prevent. So it is checked
/// the only way it can be: by reading the source.
///
/// The rule is deliberately blunt: a desktop's name may not appear in Dart
/// *code* at all, not merely in a comparison. Deciding whether an occurrence is
/// a branch, a label or a log line is not something a regular expression can be
/// trusted to do, and the strict version has no false negatives. Prose is where
/// these names belong, so comments are stripped before the scan and this file's
/// own doc comment names both desktops freely.
///
/// The cost is that a genuine need to put one of these words in Dart code, in
/// user-facing copy say, trips the guardrail. That is meant to be a
/// conversation rather than a wall: record it in [allowedOccurrences] below,
/// with the reason, the way the runner's one exception is recorded.
///
/// The runner half of the same rule lives in `scripts/check_linux_runner.py`
/// (`desktop_neutrality_problems`), which scans `linux/` for the same two
/// shapes and carries the one grandfathered exception Linthra still has: an
/// X11-only title bar decoration choice, kept because GTK 3 implements no
/// xdg-decoration protocol to defer to. Its allowance covers exactly one
/// occurrence, and so does each entry here.
void main() {
  /// The environment variables a desktop session sets to say what it is.
  /// Reading one of them is the Dart-side shape of "detect the desktop".
  const List<String> sessionVariables = <String>[
    'XDG_CURRENT_DESKTOP',
    'XDG_SESSION_DESKTOP',
    'DESKTOP_SESSION',
    'KDE_FULL_SESSION',
    'KDE_SESSION_VERSION',
    'GNOME_DESKTOP_SESSION_ID',
  ];

  /// Desktop and window-manager names, kept identical to the Python checker's
  /// `DESKTOP_NAMES`. Names that are ordinary words too (MATE's `marco`,
  /// Cinnamon's `muffin`) are deliberately absent: nothing would plausibly
  /// branch on them, and a list that produces false positives is a list people
  /// start ignoring.
  const List<String> desktopNames = <String>[
    'gnome',
    'kde',
    'plasma',
    'kwin',
    'mutter',
    'xfce',
    'xfwm4',
    'cinnamon',
    'budgie',
    'lxqt',
    'pantheon',
    'deepin',
  ];

  /// Occurrences that have been looked at and accepted, as `'<path>:<name>'`,
  /// each with its reason beside it. One entry excuses one occurrence, so a
  /// second one in the same file still fails.
  ///
  /// Empty, and the goal is to keep it that way: every Linux integration
  /// Linthra has goes through a standard that answers on both desktops, so
  /// there is nothing for Dart to name.
  const List<String> allowedOccurrences = <String>[];

  final String alternatives = desktopNames.join('|');
  final RegExp desktopName = RegExp(
    '(?<![A-Za-z0-9])(?:$alternatives)(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  /// The offset just past the string literal starting at [start].
  ///
  /// Handles the four quote forms plus the `r` prefix. Nothing is blanked:
  /// string contents are exactly what the scan is looking for, so this only
  /// moves the cursor past them.
  int skipString(String source, int start) {
    int index = start;
    final bool raw = source[index] == 'r';
    if (raw) {
      index++;
    }
    final String quote = source[index];
    final String triple = quote * 3;
    if (source.startsWith(triple, index)) {
      final int close = source.indexOf(triple, index + 3);
      return close == -1 ? source.length : close + 3;
    }
    index++;
    while (index < source.length) {
      final String char = source[index];
      if (char == '\n') {
        // An unterminated single-quoted string. Stop at the line rather than
        // running to the end of the file.
        return index;
      }
      if (!raw && char == r'\') {
        index += 2;
        continue;
      }
      if (char == quote) {
        return index + 1;
      }
      index++;
    }
    return source.length;
  }

  /// [source] with `//` and `/* */` comments replaced by spaces of the same
  /// length, so an offset into the result is an offset into the original.
  ///
  /// Prose names both desktops constantly, and should: this file's own doc
  /// comment does. It is a runtime branch on a desktop's name that is the
  /// problem, so only code is scanned.
  ///
  /// String literals are stepped over before comment delimiters are looked
  /// for, and that ordering is load-bearing rather than tidiness. Dart code in
  /// this repository contains `'*/*'` (an HTTP Accept header), and reading the
  /// `/*` inside it as the start of a block comment blanked everything to the
  /// end of the file, because no `*/` followed: 822 lines across two client
  /// files were invisible to this scan. A guardrail with a silent blind spot is
  /// worse than no guardrail, so the ordering is covered by a test below.
  String withoutComments(String source) {
    final List<String> out = source.split('');
    int index = 0;
    while (index < source.length) {
      final String char = source[index];
      final bool opensString = char == "'" ||
          char == '"' ||
          (char == 'r' &&
              index + 1 < source.length &&
              (source[index + 1] == "'" || source[index + 1] == '"'));
      if (opensString) {
        index = skipString(source, index);
      } else if (source.startsWith('//', index)) {
        int end = source.indexOf('\n', index);
        if (end == -1) {
          end = source.length;
        }
        for (int at = index; at < end; at++) {
          out[at] = ' ';
        }
        index = end;
      } else if (source.startsWith('/*', index)) {
        final int close = source.indexOf('*/', index + 2);
        final int end = close == -1 ? source.length : close + 2;
        for (int at = index; at < end; at++) {
          if (out[at] != '\n') {
            out[at] = ' ';
          }
        }
        index = end;
      } else {
        index++;
      }
    }
    return out.join();
  }

  /// The 1-based line number [offset] falls on.
  int lineAt(String code, int offset) {
    return code.substring(0, offset).split('\n').length;
  }

  late List<File> sources;

  setUpAll(() {
    final List<FileSystemEntity> tree =
        Directory('lib').listSync(recursive: true);
    final List<File> found = <File>[];
    for (final FileSystemEntity entity in tree) {
      if (entity is File && entity.path.endsWith('.dart')) {
        found.add(entity);
      }
    }
    found.sort((File a, File b) => a.path.compareTo(b.path));
    sources = found;
  });

  test('the scan actually reads lib/, so a pass means something', () {
    expect(sources.length, greaterThan(100));
  });

  test('no Dart source reads a desktop session environment variable', () {
    final List<String> findings = <String>[];
    for (final File file in sources) {
      final String code = withoutComments(file.readAsStringSync());
      for (final String variable in sessionVariables) {
        final int at = code.indexOf(variable);
        if (at == -1) {
          continue;
        }
        findings.add('${file.path}:${lineAt(code, at)}: $variable');
      }
    }
    expect(
      findings,
      isEmpty,
      reason: 'Reading one of these is how a desktop gets detected, and every '
          'Linux integration Linthra has already goes through a standard that '
          'answers on both GNOME and KDE Plasma: portals, MPRIS, the Secret '
          'Service, freedesktop window properties. Reach for the standard '
          'instead; if there genuinely is none, document the difference in '
          'docs/desktop-compatibility-matrix.md rather than branching on it.',
    );
  });

  test('no desktop environment name appears in Dart code', () {
    final List<String> findings = <String>[];
    final List<String> unused = <String>[...allowedOccurrences];
    for (final File file in sources) {
      final String code = withoutComments(file.readAsStringSync());
      for (final RegExpMatch match in desktopName.allMatches(code)) {
        if (unused.remove('${file.path}:${match.group(0)}')) {
          continue;
        }
        final int line = lineAt(code, match.start);
        findings.add('${file.path}:$line: ${match.group(0)}');
      }
    }
    expect(
      findings,
      isEmpty,
      reason: 'A desktop name in Dart code is usually a branch that one of '
          'GNOME and KDE Plasma takes and the other does not, which is how the '
          'untested desktop becomes the one that breaks after release. The '
          'check is on the name rather than on the comparison, because telling '
          'those apart with a regular expression is not reliable, so an '
          'occurrence that is genuinely neutral is accepted by adding it to '
          'allowedOccurrences with a reason. Prose is exempt: put the name '
          'in a comment, or in docs/desktop-compatibility-matrix.md.',
    );
    expect(
      unused,
      isEmpty,
      reason: 'these allowedOccurrences entries no longer match anything, so '
          'they describe a problem that is gone; drop them.',
    );
  });

  test('a string containing a comment opener does not blank the file', () {
    // The real shape: an HTTP Accept header whose value contains `/*`, with no
    // `*/` anywhere after it. Read naively, that opens a block comment that
    // never closes and everything below it disappears from the scan.
    const String sample = "const Map<String, String> headers = {\n"
        "  'Accept': '*/*',\n"
        "};\n"
        "const String later = 'gnome-shell';\n";
    final String code = withoutComments(sample);
    expect(code.contains('const String later'), isTrue);
    expect(desktopName.allMatches(code).length, 1);
  });

  test('comments are still stripped after a string', () {
    const String sample = "const String a = 'plain';\n"
        '// GNOME is named here and must not count.\n'
        'const String b = 1;\n';
    final String code = withoutComments(sample);
    expect(desktopName.allMatches(code), isEmpty);
    expect(code.contains('const String b'), isTrue);
  });

  test('every Dart source survives the comment stripper', () {
    // The property the two cases above are examples of: stripping comments
    // must never remove code. Checked across the whole of lib/, so a new
    // string shape that confuses the scanner is caught where it lands.
    final List<String> shrunk = <String>[];
    for (final File file in sources) {
      final String source = file.readAsStringSync();
      final String code = withoutComments(source);
      final int before = source.split('\n').length;
      final int after = code.split('\n').length;
      if (before != after) {
        shrunk.add('${file.path}: $before lines in, $after out');
      }
    }
    expect(shrunk, isEmpty);
  });

  test('the scan reads code and ignores prose', () {
    // Guards the scan itself: a doc comment naming both desktops (this file
    // has several) must not count, and the same word in code must.
    const String sample = '/// GNOME and KDE Plasma both have the portal.\n'
        '// DESKTOP_SESSION is not read here.\n'
        "const String wanted = 'gnome-shell';\n";
    final String code = withoutComments(sample);
    expect(code.contains('DESKTOP_SESSION'), isFalse);
    expect(desktopName.allMatches(code).length, 1);
    expect(desktopName.firstMatch(code)!.group(0), 'gnome');
  });
}
