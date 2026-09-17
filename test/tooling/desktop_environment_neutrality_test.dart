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
/// The runner half of the same rule lives in `scripts/check_linux_runner.py`
/// (`desktop_neutrality_problems`), which scans `linux/` for the same two
/// shapes and carries the one grandfathered exception Linthra still has: an
/// X11-only title bar decoration choice, kept because GTK 3 implements no
/// xdg-decoration protocol to defer to. Dart has no equivalent, so there is no
/// allowlist here.
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

  final String alternatives = desktopNames.join('|');
  final RegExp desktopName = RegExp(
    '(?<![A-Za-z0-9])(?:$alternatives)(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  /// [source] with `//` and `/* */` comments replaced by spaces of the same
  /// length, so an offset into the result is an offset into the original.
  ///
  /// Prose names both desktops constantly, and should: this file's own doc
  /// comment does. It is a runtime branch on a desktop's name that is the
  /// problem, so only code is scanned.
  String withoutComments(String source) {
    final List<String> out = source.split('');
    int index = 0;
    while (index < source.length) {
      if (source.startsWith('//', index)) {
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

  test('no Dart source compares against a desktop environment name', () {
    final List<String> findings = <String>[];
    for (final File file in sources) {
      final String code = withoutComments(file.readAsStringSync());
      for (final RegExpMatch match in desktopName.allMatches(code)) {
        final int line = lineAt(code, match.start);
        findings.add('${file.path}:$line: ${match.group(0)}');
      }
    }
    expect(
      findings,
      isEmpty,
      reason: 'A desktop name in Dart code means a branch that one of GNOME '
          'and KDE Plasma takes and the other does not, which is how the '
          'untested desktop becomes the one that breaks after release. See '
          'docs/desktop-compatibility-matrix.md.',
    );
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
