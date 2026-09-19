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
/// What this does NOT prove. The scan reads literal spellings, so a name built
/// another way is invisible to it: `'\u004bDE'` is `KDE` to the Dart compiler
/// and not to this. Review found that, and it is left alone on purpose. Every
/// round of hardening this scanner has added another proxy (raw strings, split
/// quotes, adjacency, prefixes, interpolation, nested comments), and decoding
/// escapes properly means lexing Dart, which means the `analyzer` package
/// rather than the hand-rolled walk in this file. See #663.
///
/// So read a pass here as "nobody did this by accident", not as "this cannot be
/// done". The accidents are the realistic case and the ones it catches: a
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
  /// worse than no guardrail, so the ordering is covered by tests below, one of
  /// which checks the whole of `lib/` for code that got blanked.
  String withoutComments(String source) {
    final List<String> out = source.split('');
    int index = 0;
    while (index < source.length) {
      if (opensString(source, index)) {
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
        // Dart block comments nest, which C's do not, so the first `*/` is not
        // necessarily the end. Treating it as the end leaves the tail of the
        // outer comment visible to the scan, and prose is exactly where these
        // names belong, so `/* outer /* inner */ GNOME */` would fail the
        // whole suite on a comment that compiles fine.
        //
        // Shared with the interpolation walk rather than repeated here: the
        // recurring bug in this file has been one scanner learning something
        // its callers did not.
        final int end = skipBlockComment(source, index);
        for (int blank = index; blank < end; blank++) {
          if (out[blank] != '\n') {
            out[blank] = ' ';
          }
        }
        index = end;
      } else {
        index++;
      }
    }
    return out.join();
  }

  /// [code] with the seam between adjacent string literals closed up, and a map
  /// from each offset in the result back to the offset it came from.
  ///
  /// Two literals separated only by whitespace are one string in Dart: `'K'
  /// 'DE'` is `KDE` before anything runs, and `'K' r'DE'` is too. The scan looks
  /// for a name as contiguous letters, so without this a desktop check written
  /// that way sits in neither half and passes.
  ///
  /// The seams are found by walking literal *tokens*, not by matching quote
  /// pairs anywhere in the text. An earlier version used the pattern
  /// `["']\s*r?["']` over the whole file, which also matches the two inner
  /// quotes of `'"K" "DE"'`: one literal whose body happens to contain quoted
  /// words. It closed those up and reported `KDE` in a file that builds no such
  /// string, so the guardrail rejected correct source. Only a gap *between* two
  /// literals can be a seam, and that is a question about tokens.
  ///
  /// The map is what keeps the report honest. A seam can span lines, and Dart
  /// splits long strings across lines constantly, so the joined text has fewer
  /// lines than the file it came from. A line counted in the joined text would
  /// be wrong for every finding after the first seam; findings are looked up
  /// through this map instead.
  (String, List<int>) withoutLiteralSeams(String code) {
    final StringBuffer joined = StringBuffer();
    final List<int> origin = <int>[];
    void copy(int from, int to) {
      for (int at = from; at < to; at++) {
        joined.write(code[at]);
        origin.add(at);
      }
    }

    int index = 0;
    int cursor = 0;
    ({int end, int bodyStart, int bodyEnd})? previous;
    while (cursor < code.length) {
      if (!opensString(code, cursor)) {
        cursor++;
        continue;
      }
      final int start = cursor;
      final ({int end, int bodyStart, int bodyEnd}) literal =
          stringSpan(code, cursor);
      if (previous != null) {
        final String between = code.substring(previous.end, start);
        // Whitespace, optionally with the next literal's `r` prefix in it: the
        // two are one string. Anything else (a comma, an operator, a name) and
        // they are two.
        if (between.replaceFirst('r', '').trim().isEmpty) {
          // Delete exactly the closing quote, the gap and the opening quote, so
          // the two bodies meet. Keeping either quote would leave them apart.
          copy(index, previous.bodyEnd);
          index = literal.bodyStart;
        }
      }
      previous = literal;
      cursor = literal.end;
    }
    copy(index, code.length);
    return (joined.toString(), origin);
  }

  /// The 1-based line number [offset] falls on.
  int lineAt(String code, int offset) {
    return code.substring(0, offset).split('\n').length;
  }

  /// The body span of every string literal in [source], in order.
  ///
  /// Literal bodies are what the scan actually reads, and they are what the
  /// stripper has historically eaten: `'*/*'` was read as opening a block
  /// comment and took 822 lines with it. So "no literal body was blanked" is
  /// the property worth asserting across the whole tree, and unlike a
  /// last-character sentinel it cannot be confused by what a file ends with.
  List<(int, int)> literalBodies(String source) {
    final List<(int, int)> bodies = <(int, int)>[];
    int index = 0;
    while (index < source.length) {
      if (source.startsWith('//', index)) {
        final int newline = source.indexOf('\n', index);
        index = newline == -1 ? source.length : newline;
        continue;
      }
      if (source.startsWith('/*', index)) {
        index = skipBlockComment(source, index);
        continue;
      }
      if (opensString(source, index)) {
        final ({int end, int bodyStart, int bodyEnd}) literal =
            stringSpan(source, index);
        bodies.add((literal.bodyStart, literal.bodyEnd));
        index = literal.end;
        continue;
      }
      index++;
    }
    return bodies;
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
      final String stripped = withoutComments(file.readAsStringSync());
      final (String code, List<int> origin) = withoutLiteralSeams(stripped);
      for (final String variable in sessionVariables) {
        final int at = code.indexOf(variable);
        if (at == -1) {
          continue;
        }
        final int line = lineAt(stripped, origin[at]);
        findings.add('${file.path}:$line: $variable');
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
      final String stripped = withoutComments(file.readAsStringSync());
      final (String code, List<int> origin) = withoutLiteralSeams(stripped);
      for (final RegExpMatch match in desktopName.allMatches(code)) {
        if (unused.remove('${file.path}:${match.group(0)}')) {
          continue;
        }
        final int line = lineAt(stripped, origin[match.start]);
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

  test('literalBodies finds bodies and ignores commented-out ones', () {
    // The only moving part of the whole-tree check below, so it gets its own
    // case. A quote inside a comment is not a literal.
    const String sample = "const String a = 'keep';\n"
        "// const String b = 'commented';\n"
        "/* const String c = 'blocked'; */\n";
    final List<(int, int)> bodies = literalBodies(sample);
    expect(bodies.length, 1);
    final (int start, int end) = bodies.single;
    expect(sample.substring(start, end), 'keep');
  });

  test('a file ending in a block comment is not a failure', () {
    // The shape that broke the previous sentinel: legal Dart, and the stripper
    // is right to blank that comment.
    const String sample = 'void main() {}\n'
        '/* trailing\n'
        '   note */\n';
    final String code = withoutComments(sample);
    expect(code.contains('void main'), isTrue);
    expect(desktopName.allMatches(code), isEmpty);
    for (final (int, int) body in literalBodies(sample)) {
      final (int start, int end) = body;
      expect(code.substring(start, end), sample.substring(start, end));
    }
  });

  test('no string literal in lib/ is eaten by the comment stripper', () {
    // The property the two cases above are examples of, asserted across the
    // whole tree so a new string shape is caught where it lands.
    //
    // Two earlier versions of this test were worse, and both are worth
    // recording because the failure modes are opposite.
    //
    // The first compared line counts. `withoutComments` writes spaces and keeps
    // every newline, so the count is identical whether it blanked one comment
    // or the whole file: the assertion could never fail, and it passed on the
    // very bug it was written for.
    //
    // The second took the file's last character of code as a sentinel and
    // guessed which trailing lines were comments by looking at them one at a
    // time. A file ending in a legal multi-line `/* ... */` broke that guess:
    // the closing line looked like a comment, the opening line did not, so the
    // test demanded that `withoutComments` preserve text inside a comment and
    // failed on correct source.
    //
    // Literal bodies avoid both. They are what the scan reads, they are what
    // the stripper has actually eaten, and whether one survives is a question
    // with an answer rather than a guess.
    final List<String> damaged = <String>[];
    for (final File file in sources) {
      final String source = file.readAsStringSync();
      final String code = withoutComments(source);
      for (final (int, int) body in literalBodies(source)) {
        final (int start, int end) = body;
        if (code.substring(start, end) == source.substring(start, end)) {
          continue;
        }
        damaged.add('${file.path}:${lineAt(source, start)}: the literal '
            '${source.substring(start, end)} was blanked');
        break;
      }
    }
    expect(damaged, isEmpty);
  });

  test('a nested block comment is stripped whole', () {
    // Dart nests block comments, C does not. Stopping at the first `*/` leaves
    // the tail of the outer one exposed, and since prose is where these names
    // belong, the guardrail would fail the suite on a legal comment.
    const String sample = '/* outer /* inner */ GNOME */\n'
        "const String kept = 'value';\n";
    final String code = withoutComments(sample);
    expect(desktopName.allMatches(code), isEmpty);
    expect(code.contains('const String kept'), isTrue);
  });

  test('adjacent string literals are read as the string they form', () {
    // `'K' 'DE'` is the single string `KDE` before anything runs, so a scan
    // that reads the halves separately finds the name in neither.
    const String sample = "const String shell = 'K' 'DE';\n";
    final (String code, _) = withoutLiteralSeams(withoutComments(sample));
    expect(desktopName.allMatches(code).length, 1);
    expect(desktopName.firstMatch(code)!.group(0), 'KDE');
  });

  test('a seam spanning lines keeps the line numbers honest', () {
    // The seam may hold a newline, and dropping it would shift every line
    // number below it in the report.
    const String sample = 'const String a = 1;\n'
        "const String shell = 'K'\n"
        "    'DE';\n";
    final String stripped = withoutComments(sample);
    final (String code, List<int> origin) = withoutLiteralSeams(stripped);
    final RegExpMatch match = desktopName.firstMatch(code)!;
    expect(match.group(0), 'KDE');
    // The name starts on line 2 of the file. The joined text is a line
    // shorter, so counting newlines in it is not the same question.
    expect(lineAt(stripped, origin[match.start]), 2);
  });

  test('literals separated by anything else are left alone', () {
    // The other direction: a comma makes them two strings, and joining them
    // would invent a name nothing forms.
    const String sample = "const List<String> pair = <String>['K', 'DE'];\n";
    final (String code, _) = withoutLiteralSeams(withoutComments(sample));
    expect(desktopName.allMatches(code), isEmpty);
  });

  test('a nested literal inside an interpolation is not the outer close', () {
    // Valid Dart, and the shape that broke everything after it: taking the
    // quote that opens `'*/*'` for the outer string's close leaves the cursor
    // inside that literal, where the `/*` opens a block comment with no `*/`
    // after it.
    const String sample = "final String v = '"
        "\${format('*/*')}';\n"
        "const String kept = 'value';\n";
    final String code = withoutComments(sample);
    expect(code.contains('const String kept'), isTrue);
    expect(code, equals(sample));
  });

  test('an r-prefixed adjacent literal still joins', () {
    // The `r` sits between the two literals, so the seam has to allow for it.
    const String sample = "const String shell = 'K' r'DE';\n";
    final (String code, _) = withoutLiteralSeams(withoutComments(sample));
    expect(desktopName.allMatches(code).length, 1);
    expect(desktopName.firstMatch(code)!.group(0), 'KDE');
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

/// Whether a string literal starts at [at], `r` prefix included.
bool opensString(String source, int at) {
  final String char = source[at];
  if (char == "'" || char == '"') {
    return true;
  }
  return char == 'r' &&
      at + 1 < source.length &&
      (source[at + 1] == "'" || source[at + 1] == '"');
}

/// The offset just past the string literal starting at [start].
///
/// Handles the four quote forms plus the `r` prefix. Nothing is blanked:
/// string contents are exactly what the scan is looking for, so this only
/// moves the cursor past them.
///
/// `${...}` interpolations are stepped through rather than read as text,
/// because the expression inside one can hold string literals of its own and
/// those can hold anything. Taking the first quote of a nested literal for
/// the outer string's close leaves the cursor *inside* that literal, and a
/// `/*` in it then opens a block comment that blanks the rest of the file.
/// `'${format('*/*')}'` is valid Dart and does exactly that.
int skipString(String source, int start) => stringSpan(source, start).end;

/// The literal starting at [start], as the offsets that bound it and its body.
///
/// `end` is just past the closing quote. `bodyStart` and `bodyEnd` bound the
/// contents, which is what lets a caller join two adjacent literals by deleting
/// exactly the quotes between them.
({int end, int bodyStart, int bodyEnd}) stringSpan(String source, int start) {
  int index = start;
  final bool raw = source[index] == 'r';
  if (raw) {
    index++;
  }
  final String quote = source[index];
  final bool triple = source.startsWith(quote * 3, index);
  final String terminator = triple ? quote * 3 : quote;
  index += terminator.length;
  final int bodyStart = index;
  while (index < source.length) {
    if (source.startsWith(terminator, index)) {
      return (
        end: index + terminator.length,
        bodyStart: bodyStart,
        bodyEnd: index,
      );
    }
    final String char = source[index];
    if (!raw && char == r'\') {
      index += 2;
      continue;
    }
    if (!triple && char == '\n') {
      // An unterminated single-quoted string. Stop at the line rather than
      // running to the end of the file.
      return (end: index, bodyStart: bodyStart, bodyEnd: index);
    }
    if (!raw &&
        char == r'$' &&
        index + 1 < source.length &&
        source[index + 1] == '{') {
      index = skipInterpolation(source, index + 2);
      continue;
    }
    index++;
  }
  return (end: source.length, bodyStart: bodyStart, bodyEnd: source.length);
}

/// The offset just past the `}` that closes a `${` opened just before
/// [start].
///
/// Nested literals are handed back to [skipString], so an interpolation
/// holding a string holding another interpolation still ends in the right
/// place. Braces are counted so `${a${b}c}` does not stop at the inner one.
int skipInterpolation(String source, int start) {
  int depth = 1;
  int index = start;
  while (index < source.length) {
    // Comments first. An interpolated expression may hold them, and a quote
    // inside one is not a string: `'${/* " */ 0}'` is valid Dart, and reading
    // that `"` as a literal opening ran the cursor to the end of the file,
    // leaving everything after it unstripped. That is the same mistake as
    // reading a `/*` inside a string as a comment, in the other direction.
    if (source.startsWith('//', index)) {
      final int newline = source.indexOf('\n', index);
      index = newline == -1 ? source.length : newline;
      continue;
    }
    if (source.startsWith('/*', index)) {
      index = skipBlockComment(source, index);
      continue;
    }
    if (opensString(source, index)) {
      index = skipString(source, index);
      continue;
    }
    final String char = source[index];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return index + 1;
      }
    }
    index++;
  }
  return source.length;
}

/// The offset just past the block comment opening at [start].
///
/// Dart nests block comments, so the first `*/` is not necessarily the end.
/// Shared by the stripper and by the interpolation walk so both agree on where
/// one stops.
int skipBlockComment(String source, int start) {
  int depth = 0;
  int index = start;
  while (index < source.length) {
    if (source.startsWith('/*', index)) {
      depth++;
      index += 2;
    } else if (source.startsWith('*/', index)) {
      depth--;
      index += 2;
      if (depth == 0) {
        return index;
      }
    } else {
      index++;
    }
  }
  return source.length;
}
