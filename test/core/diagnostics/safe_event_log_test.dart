import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';

void main() {
  group('SafeEventLog', () {
    test('records events oldest-first and renders "category: detail" lines',
        () {
      final SafeEventLog log = SafeEventLog();
      log.record('lifecycle', 'resumed');
      log.record('output', 'cast');

      expect(log.lines, <String>['lifecycle: resumed', 'output: cast']);
      expect(log.events.first.category, 'lifecycle');
      expect(log.events.first.detail, 'resumed');
      expect(log.isNotEmpty, isTrue);
    });

    test('caps at capacity, dropping the oldest events', () {
      final SafeEventLog log = SafeEventLog(capacity: 3);
      for (int i = 0; i < 5; i++) {
        log.record('n', '$i');
      }

      expect(log.lines, <String>['n: 2', 'n: 3', 'n: 4']);
    });

    test('clear empties the log', () {
      final SafeEventLog log = SafeEventLog()..record('a', 'b');
      expect(log.isEmpty, isFalse);

      log.clear();

      expect(log.isEmpty, isTrue);
      expect(log.lines, isEmpty);
    });

    test('the exposed events list is unmodifiable', () {
      final SafeEventLog log = SafeEventLog()..record('a', 'b');
      expect(
        () => log.events.add(const SafeEvent('x', 'y')),
        throwsUnsupportedError,
      );
    });

    test('the recorded structural lines carry no secret', () {
      final SafeEventLog log = SafeEventLog()
        ..record('lifecycle', 'paused')
        ..record('output', 'local')
        ..record('error', 'networkDropped');

      for (final String line in log.lines) {
        expect(line, isNot(contains('://')));
        expect(line.toLowerCase(), isNot(contains('token')));
        expect(line.toLowerCase(), isNot(contains('password')));
      }
    });
  });
}
