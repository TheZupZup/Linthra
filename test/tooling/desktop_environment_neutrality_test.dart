import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
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
/// a branch, a label or a log line is not something a scan can be trusted to
/// do, and the strict version has no false negatives. Prose is where these
/// names belong, so comments are not read and this file's own doc comment
/// names both desktops freely.
///
/// The cost is that a genuine need to put one of these words in Dart code, in
/// user-facing copy say, trips the guardrail. That is meant to be a
/// conversation rather than a wall: record it in [allowedOccurrences] below,
/// with the reason, the way the runner's one exception is recorded.
///
/// The source is read by the `analyzer` package, the language's own front end
/// (#663), rather than by a hand-rolled walk over text. A string is checked
/// for what it *denotes*: escapes decoded (`'KDE'` is `KDE`), adjacent
/// literals joined (`'K' 'DE'`), an interpolated string literal folded into
/// the string around it (`'K${'DE'}'`), comments gone at any nesting.
/// Identifiers and every other token are checked as written.
///
/// What this does NOT prove. Literals and names are all it reads, so a name
/// built at run time (from character codes, a list joined, a file) is
/// invisible. So it reads a pass as "nobody did this by accident". The
/// accidents are the realistic case and the ones it catches: a
/// `Platform.environment['XDG_CURRENT_DESKTOP']` lookup, a `contains('KDE')`,
/// a desktop name in a user-facing string that should have been generic.
///
/// The runner half of the same rule lives in `scripts/check_linux_runner.py`
/// (`desktop_neutrality_problems`), which scans `linux/` for the same two
/// shapes and carries the one grandfathered exception Linthra still has: an
/// X11-only title bar decoration choice, kept because GTK 3 implements no
/// xdg-decoration protocol to defer to. Its allowance covers exactly one
/// occurrence, and so does each entry here.
void main() {
  /// Occurrences that have been looked at and accepted, as `'<path>:<name>'`,
  /// each with its reason beside it. One entry excuses one occurrence, so a
  /// second one in the same file still fails.
  ///
  /// Empty, and the goal is to keep it that way: every Linux integration
  /// Linthra has goes through a standard that answers on both desktops, so
  /// there is nothing for Dart to name.
  const List<String> allowedOccurrences = <String>[];

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

  test('every source in lib/ parses, so none is read only in part', () {
    // A parse error leaves the analyzer recovering, and what it recovers may
    // not be the code. lib/ compiles, so this holds; the test says so.
    final List<String> broken = <String>[
      for (final File file in sources)
        if (parseString(
          content: file.readAsStringSync(),
          path: file.path,
          throwIfDiagnostics: false,
        ).errors.isNotEmpty)
          file.path,
    ];
    expect(broken, isEmpty);
  });

  test('no Dart source reads a desktop session environment variable', () {
    final List<String> findings = <String>[
      for (final File file in sources)
        for (final DesktopFinding finding
            in scanDesktopNeutrality(file.readAsStringSync()).variables)
          '${file.path}:${finding.line}: ${finding.text}',
    ];
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
      for (final DesktopFinding finding
          in scanDesktopNeutrality(file.readAsStringSync()).names) {
        if (unused.remove('${file.path}:${finding.text}')) {
          continue;
        }
        findings.add('${file.path}:${finding.line}: ${finding.text}');
      }
    }
    expect(
      findings,
      isEmpty,
      reason: 'A desktop name in Dart code is usually a branch that one of '
          'GNOME and KDE Plasma takes and the other does not, which is how the '
          'untested desktop becomes the one that breaks after release. The '
          'check is on the name rather than on the comparison, because telling '
          'those apart by reading the source is not reliable, so an '
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

  group('what the scan reads', () {
    List<String> names(String source) => <String>[
          for (final DesktopFinding finding
              in scanDesktopNeutrality(source).names)
            finding.text,
        ];

    test('code, not prose', () {
      // A doc comment naming both desktops (this file has several) must not
      // count, and the same word in code must.
      const String sample = '/// GNOME and KDE Plasma both have the portal.\n'
          '// DESKTOP_SESSION is not read here.\n'
          "const String wanted = 'gnome-shell';\n";
      final DesktopScan scan = scanDesktopNeutrality(sample);
      expect(scan.variables, isEmpty);
      expect(<String>[for (final DesktopFinding f in scan.names) f.text],
          <String>['gnome']);
    });

    test('a string holding a comment opener hides nothing after it', () {
      // The real shape: an HTTP Accept header whose value contains `/*`.
      const String sample = "const Map<String, String> headers = {\n"
          "  'Accept': '*/*',\n"
          "};\n"
          "const String later = 'gnome-shell';\n";
      expect(names(sample), <String>['gnome']);
    });

    test('a nested block comment is skipped whole', () {
      const String sample = '/* outer /* inner */ GNOME */\n'
          "const String kept = 'value';\n";
      expect(names(sample), isEmpty);
    });

    test('a file ending in a block comment is fine', () {
      const String sample = 'void main() {}\n'
          '/* trailing\n'
          '   KDE note */\n';
      expect(names(sample), isEmpty);
    });

    test('adjacent literals are read as the string they form', () {
      expect(names("const String shell = 'K' 'DE';\n"), <String>['KDE']);
      expect(names("const String shell = 'K' r'DE';\n"), <String>['KDE']);
    });

    test('a joined name is reported on the line it starts on', () {
      const String sample = 'const int a = 1;\n'
          "const String shell = 'K'\n"
          "    'DE';\n";
      final DesktopFinding finding = scanDesktopNeutrality(sample).names.single;
      expect(finding.text, 'KDE');
      expect(finding.line, 2);
    });

    test('literals separated by anything else are left alone', () {
      expect(
          names("const List<String> pair = <String>['K', 'DE'];\n"), isEmpty);
    });

    test('quoted words inside one literal are not joined', () {
      // One of the false positives #654 shipped a fix for: a single literal
      // holding the text `"K" "DE"` is not the string `KDE`.
      expect(names("const String help = '\"K\" \"DE\"';\n"), isEmpty);
    });

    test('a quote inside an interpolated comment ends nothing', () {
      // `'${/* " */ 0}'` is valid Dart, and once sent a hand-rolled walker to
      // the end of the file, taking everything after it out of the scan.
      const String sample = "final String v = '\${/* \" */ 0}';\n"
          "const String later = 'KDE';\n";
      expect(names(sample), <String>['KDE']);
    });

    test('a nested literal inside an interpolation is read', () {
      const String sample = "final String v = '\${format('*/*')}';\n"
          "const String later = 'xfce';\n";
      expect(names(sample), <String>['xfce']);
    });

    test('a name spelled with escapes is caught', () {
      // Each of these is `KDE` to the Dart compiler (#663).
      for (final String spelling in <String>[
        r"'KDE'",
        r"'\u{4b}DE'",
        r"'\x4b\x44\x45'",
        r"'K\x44E'",
      ]) {
        expect(names('const String shell = $spelling;\n'), <String>['KDE'],
            reason: spelling);
      }
    });

    test('a raw string is read as written, escapes and all', () {
      expect(names(r"const String path = r'\x4b\x44\x45';" '\n'), isEmpty);
    });

    test('an interpolated string literal is folded into its string', () {
      expect(names("const String shell = 'K\${'DE'}';\n"), <String>['KDE']);
      // Not across anything else: the value of `x` is not known here, and
      // guessing it empty would invent a name.
      expect(names("String shell(String x) => 'K\${x}DE';\n"), isEmpty);
    });

    test('a name used as an identifier is caught', () {
      expect(names('const bool kde_session = true;\n'), <String>['kde']);
    });

    test('a session variable is caught in a string or a name', () {
      for (final String sample in <String>[
        "final String? d = Platform.environment['XDG_CURRENT_DESKTOP'];\n",
        r"final String? d = Platform.environment['XDG_\x43URRENT_DESKTOP'];"
            '\n',
        'const int XDG_SESSION_DESKTOP = 1;\n',
      ]) {
        expect(
          <String>[
            for (final DesktopFinding f
                in scanDesktopNeutrality(sample).variables)
              f.text,
          ],
          hasLength(1),
          reason: sample,
        );
      }
    });
  });
}

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

final RegExp desktopName = RegExp(
  '(?<![A-Za-z0-9])(?:${desktopNames.join('|')})(?![A-Za-z0-9])',
  caseSensitive: false,
);

/// One name or variable the scan found, and the line it starts on.
typedef DesktopFinding = ({int line, String text});

/// Everything one source names: desktops, and session variables.
typedef DesktopScan = ({
  List<DesktopFinding> names,
  List<DesktopFinding> variables,
});

/// Scans [source] the way the compiler reads it: every string for what it
/// denotes (see [_StringValues]), every other token as written. Comments are
/// not tokens here, so prose never counts.
DesktopScan scanDesktopNeutrality(String source) {
  final ParseStringResult parsed =
      parseString(content: source, throwIfDiagnostics: false);
  final LineInfo lines = parsed.lineInfo;
  final List<DesktopFinding> names = <DesktopFinding>[];
  final List<DesktopFinding> variables = <DesktopFinding>[];

  void check(int offset, String text) {
    final int line = lines.getLocation(offset).lineNumber;
    for (final RegExpMatch match in desktopName.allMatches(text)) {
      names.add((line: line, text: match.group(0)!));
    }
    for (final String variable in sessionVariables) {
      if (text.contains(variable)) {
        variables.add((line: line, text: variable));
      }
    }
  }

  final _StringValues strings = _StringValues();
  parsed.unit.accept(strings);
  final List<(int, String)> found = <(int, String)>[
    ...strings.values,
    for (Token token = parsed.unit.beginToken;
        token.type != TokenType.EOF;
        token = token.next!)
      if (token.type != TokenType.STRING && !token.isSynthetic)
        (token.offset, token.lexeme),
  ]..sort(((int, String) a, (int, String) b) => a.$1.compareTo(b.$1));
  for (final (int offset, String text) in found) {
    check(offset, text);
  }
  return (names: names, variables: variables);
}

/// The value of every string in a unit, once each: adjacent literals as the
/// one string they form, and a string literal interpolated into another as
/// part of it.
class _StringValues extends RecursiveAstVisitor<void> {
  final List<(int, String)> values = <(int, String)>[];

  /// Strings already counted as part of an enclosing one.
  final Set<StringLiteral> _folded = <StringLiteral>{};

  /// What [node] denotes. A part this can't know (an interpolated variable,
  /// a call) is a NUL, which no name runs across.
  String _valueOf(StringLiteral node) {
    _folded.add(node);
    return switch (node) {
      SimpleStringLiteral() => node.value,
      AdjacentStrings() => <String>[
          for (final StringLiteral part in node.strings) _valueOf(part),
        ].join(),
      StringInterpolation() => <String>[
          for (final InterpolationElement element in node.elements)
            switch (element) {
              InterpolationString() => element.value,
              InterpolationExpression(:final Expression expression)
                  when expression is StringLiteral =>
                _valueOf(expression),
              _ => '\u0000',
            },
        ].join(),
    };
  }

  void _record(StringLiteral node) {
    if (_folded.contains(node)) return;
    values.add((node.offset, _valueOf(node)));
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    _record(node);
    super.visitAdjacentStrings(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _record(node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _record(node);
    super.visitStringInterpolation(node);
  }
}
