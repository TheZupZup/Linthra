import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/services/stability_diagnostics.dart';

void main() {
  group('StabilityDiagnostics breadcrumbs (secret-free)', () {
    test('describe* render the fixed, structural label', () {
      expect(
        StabilityDiagnostics.describeLifecycle('resumed'),
        'lifecycle: resumed',
      );
      expect(StabilityDiagnostics.describeOutput('cast'), 'output -> cast');
      expect(
        StabilityDiagnostics.describePrecache('start:3'),
        'precache: start:3',
      );
      expect(
        StabilityDiagnostics.describePlaybackError('sessionExpired'),
        'playback error: sessionExpired',
      );
    });

    test('a breadcrumb carries only its label — no room to leak a secret', () {
      // The call sites pass enum names / fixed labels by construction; these
      // assert the rendered line is exactly that label with a fixed prefix, so
      // a token, authenticated URL, or path can never ride along.
      final List<String> lines = <String>[
        StabilityDiagnostics.describeLifecycle('paused'),
        StabilityDiagnostics.describeOutput('local'),
        StabilityDiagnostics.describePrecache('skip:repeat-one'),
        StabilityDiagnostics.describePlaybackError('networkDropped'),
      ];
      for (final String line in lines) {
        expect(line, isNot(contains('://')));
        expect(line, isNot(contains('api_key')));
        expect(line.toLowerCase(), isNot(contains('token')));
        expect(line.toLowerCase(), isNot(contains('authorization')));
        expect(line.toLowerCase(), isNot(contains('password')));
      }
    });

    test('the logging entry points never throw', () {
      expect(
        () {
          StabilityDiagnostics.lifecycle('resumed');
          StabilityDiagnostics.output('cast');
          StabilityDiagnostics.precache('start:1');
          StabilityDiagnostics.playbackError('unknown');
        },
        returnsNormally,
      );
    });
  });

  group('StabilityDiagnostics recent-event recording', () {
    setUp(SafeEventLog.instance.clear);
    tearDown(SafeEventLog.instance.clear);

    test('records each breadcrumb into the shared SafeEventLog', () {
      StabilityDiagnostics.lifecycle('resumed');
      StabilityDiagnostics.output('cast');
      StabilityDiagnostics.precache('start:3');
      StabilityDiagnostics.playbackError('load');

      expect(SafeEventLog.instance.lines, <String>[
        'lifecycle: resumed',
        'output: cast',
        'precache: start:3',
        'error: load',
      ]);
    });

    test('the recorded lines carry no secret', () {
      StabilityDiagnostics.lifecycle('paused');
      StabilityDiagnostics.playbackError('networkDropped');

      for (final String line in SafeEventLog.instance.lines) {
        expect(line, isNot(contains('://')));
        expect(line.toLowerCase(), isNot(contains('token')));
        expect(line.toLowerCase(), isNot(contains('password')));
      }
    });
  });

  group('StabilityDiagnostics retained fields for diagnostics', () {
    setUp(SafeEventLog.instance.clear);
    tearDown(SafeEventLog.instance.clear);

    test('lifecycle retains the last state seen', () {
      StabilityDiagnostics.lifecycle('inactive');
      StabilityDiagnostics.lifecycle('paused');
      expect(StabilityDiagnostics.lastLifecycleState, 'paused');
    });

    test('backgroundPlaybackState retains and records the status', () {
      StabilityDiagnostics.backgroundPlaybackState('buffering');
      expect(StabilityDiagnostics.playbackStateAtBackground, 'buffering');
      expect(SafeEventLog.instance.lines, contains('bg-playback: buffering'));
      expect(
        StabilityDiagnostics.describeBackgroundPlaybackState('playing'),
        'background playback: playing',
      );
    });

    test('playbackError retains the last interruption kind', () {
      StabilityDiagnostics.playbackError('connectionLost');
      expect(StabilityDiagnostics.lastInterruptionKind, 'connectionLost');
    });
  });
}
