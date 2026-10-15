import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// No Dart code in `lib/` listens to `package:logging` records.
///
/// The vendored Linux audio backend
/// (`third_party/just_audio_media_kit/lib/mediakit_player.dart`) logs through
/// `package:logging`, and some of those records carry the stream URL as it
/// was opened: the `load(…)` request map, the `playable is …` line, and the
/// raw libmpv `ERROR OCCURRED: Failed to open <url>.` text. A Jellyfin, Plex
/// or Subsonic stream URL holds the account's credentials in its query
/// (`ApiKey=`, `X-Plex-Token=`, `t=`/`s=`), so those records are secrets.
///
/// They are inert today for one reason only: nothing subscribes. A record with
/// no listener on `Logger.root.onRecord` (or, with
/// `hierarchicalLoggingEnabled`, on the backend's own logger) goes nowhere.
/// The moment `lib/` adds the customary
/// `Logger.root.onRecord.listen(print)`, every stream URL Linthra opens on
/// Linux is printed to stdout, which a desktop session writes to the system
/// journal. That is not something a build or any other test would notice, so
/// it is checked by reading the source.
///
/// The rule is blunt on purpose: the identifiers `onRecord` and
/// `hierarchicalLoggingEnabled` may not appear in Dart *code* in `lib/`, not
/// merely in the obvious `Logger.root.onRecord.listen` shape. Telling a safe
/// listener (one that redacts every URL) from an unsafe one is not something
/// a scan can do. If one is genuinely needed, redact the vendored log lines
/// first (as `MediaKitPlayer.redactLogText` already does for libmpv's own
/// output) and then relax this test, with the reason. Comments and strings are
/// not read, so prose may name these freely.
///
/// The source is tokenized by the `analyzer` package, the same way
/// `desktop_environment_neutrality_test.dart` reads `lib/`.
void main() {
  late List<File> sources;

  setUpAll(() {
    final List<File> found = <File>[
      for (final FileSystemEntity entity
          in Directory('lib').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart')) entity,
    ]..sort((File a, File b) => a.path.compareTo(b.path));
    sources = found;
  });

  test('the scan actually reads lib/, so a pass means something', () {
    expect(sources.length, greaterThan(100));
  });

  test('no Dart source in lib/ listens to package:logging records', () {
    final List<String> findings = <String>[
      for (final File file in sources)
        for (final LoggingListenerFinding finding
            in scanLoggingListeners(file.readAsStringSync()))
          '${file.path}:${finding.line}: ${finding.text}',
    ];
    expect(
      findings,
      isEmpty,
      reason: 'A package:logging listener in lib/ would publish the vendored '
          'Linux backend\'s log records, and those quote the stream URL being '
          'opened, credentials and all (ApiKey=, X-Plex-Token=, t=/s=): see '
          'third_party/just_audio_media_kit/lib/mediakit_player.dart, its '
          'load(), "playable is" and "ERROR OCCURRED" lines. Redact those '
          'records before attaching any listener, then revisit this test.',
    );
  });

  group('what the scan reads', () {
    List<String> found(String source) => <String>[
          for (final LoggingListenerFinding finding
              in scanLoggingListeners(source))
            finding.text,
        ];

    test('the customary root listener is caught', () {
      expect(
        found('void main() {\n'
            '  Logger.root.onRecord.listen((LogRecord r) => print(r));\n'
            '}\n'),
        <String>['onRecord'],
      );
    });

    test('a listener on a named logger, or via a cascade, is caught', () {
      expect(
        found("final Logger log = Logger('MediaKitPlayer');\n"
            'void f() {\n'
            '  log.onRecord.listen(print);\n'
            '  Logger.root..level = Level.ALL..onRecord.forEach(print);\n'
            '}\n'),
        <String>['onRecord', 'onRecord'],
      );
    });

    test('turning on hierarchical logging is caught', () {
      expect(
        found('void f() { hierarchicalLoggingEnabled = true; }\n'),
        <String>['hierarchicalLoggingEnabled'],
      );
    });

    test('prose and strings are not code', () {
      expect(
        found('/// Never call Logger.root.onRecord.listen here.\n'
            '// hierarchicalLoggingEnabled stays off.\n'
            "const String note = 'onRecord';\n"),
        isEmpty,
      );
    });
  });
}

/// The identifiers that subscribe to, or route, `package:logging` records.
const List<String> loggingListenerIdentifiers = <String>[
  'onRecord',
  'hierarchicalLoggingEnabled',
];

/// One listener identifier the scan found, and the line it is on.
typedef LoggingListenerFinding = ({int line, String text});

/// Every [loggingListenerIdentifiers] identifier in [source]'s code. Comments
/// are not tokens and string literals are skipped, so prose never counts.
List<LoggingListenerFinding> scanLoggingListeners(String source) {
  final ParseStringResult parsed =
      parseString(content: source, throwIfDiagnostics: false);
  final LineInfo lines = parsed.lineInfo;
  return <LoggingListenerFinding>[
    for (Token token = parsed.unit.beginToken;
        token.type != TokenType.EOF;
        token = token.next!)
      if (token.type == TokenType.IDENTIFIER &&
          loggingListenerIdentifiers.contains(token.lexeme))
        (
          line: lines.getLocation(token.offset).lineNumber,
          text: token.lexeme,
        ),
  ];
}
