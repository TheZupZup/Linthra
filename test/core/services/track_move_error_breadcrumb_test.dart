import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/services/stability_diagnostics.dart';

// The track-move breadcrumbs are the only StabilityDiagnostics entry points
// handed a raw error object, and what they record lands in SafeEventLog, which
// a bug report embeds. The errors that reach them in practice are exactly the
// ones that quote a private location: a FileSystemException names the user's
// music file (and so their home directory and login name), and an HTTP error
// can quote a stream URL with its token. Only the error's *type* may be
// recorded. These pin the exact line, so a change to `'$target: $error'` (or
// to anything that renders the message) fails here rather than in a report.

/// A local file error as dart:io raises it, naming a private path.
const FileSystemException _fileError = FileSystemException(
  'rename',
  '/home/alice/Music/Secret/a.flac',
  OSError('Permission denied', 13),
);

/// An error whose message quotes a tokenized stream URL.
final Exception _httpError = Exception('GET https://h/x?api_key=SECRET');

/// Everything from the two errors above that must not survive.
const List<String> _private = <String>[
  '/home',
  'alice',
  'Secret',
  'a.flac',
  'Permission denied',
  '://',
  'SECRET',
  'api_key',
  'GET ',
];

void _expectNothingPrivate(String line) {
  for (final String fragment in _private) {
    expect(line, isNot(contains(fragment)), reason: line);
  }
}

void main() {
  setUp(SafeEventLog.instance.clear);
  tearDown(SafeEventLog.instance.clear);

  group('StabilityDiagnostics.trackMoveFailedUnexpectedly', () {
    test('records the store and the error type, and nothing from the error',
        () {
      StabilityDiagnostics.trackMoveFailedUnexpectedly('playlists', _fileError);
      StabilityDiagnostics.trackMoveFailedUnexpectedly('favorites', _httpError);

      expect(SafeEventLog.instance.lines, <String>[
        'track-move-error: playlists: FileSystemException',
        'track-move-error: favorites: ${_httpError.runtimeType}',
      ]);
      for (final String line in SafeEventLog.instance.lines) {
        _expectNothingPrivate(line);
      }
    });

    test('the event detail is the store and type alone', () {
      StabilityDiagnostics.trackMoveFailedUnexpectedly('library', _fileError);

      final SafeEvent event = SafeEventLog.instance.events.single;
      expect(event.category, 'track-move-error');
      expect(event.detail, 'library: FileSystemException');
    });

    test('the debug-log line carries only the store and type', () {
      final String fileLine =
          StabilityDiagnostics.describeTrackMoveFailedUnexpectedly(
              'playHistory', _fileError);
      final String httpLine =
          StabilityDiagnostics.describeTrackMoveFailedUnexpectedly(
              'playHistory', _httpError);

      expect(
        fileLine,
        'local track move failed unexpectedly: playHistory '
        '(FileSystemException)',
      );
      _expectNothingPrivate(fileLine);
      _expectNothingPrivate(httpLine);
    });
  });
}
