import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_reporting_service.dart';
import 'package:linthra/core/services/server_playback_reporter.dart';

/// Records every reporter call as a compact `event:track@pos/dur` line, so a
/// test can assert the exact lifecycle sequence a playback scenario produced.
class _RecordingReporter implements ServerPlaybackReporter {
  final List<String> events = <String>[];

  String _line(
          String event, Track track, Duration position, Duration duration) =>
      '$event:${track.id}@${position.inMilliseconds}/${duration.inMilliseconds}';

  @override
  bool handles(Track track) => true;

  @override
  Future<void> onPlaybackStarted(
      Track track, Duration position, Duration duration) async {
    events.add(_line('started', track, position, duration));
  }

  @override
  Future<void> onPlaybackProgress(
      Track track, Duration position, Duration duration) async {
    events.add(_line('progress', track, position, duration));
  }

  @override
  Future<void> onPlaybackPaused(
      Track track, Duration position, Duration duration) async {
    events.add(_line('paused', track, position, duration));
  }

  @override
  Future<void> onPlaybackResumed(
      Track track, Duration position, Duration duration) async {
    events.add(_line('resumed', track, position, duration));
  }

  @override
  Future<void> onPlaybackStopped(
      Track track, Duration position, Duration duration) async {
    events.add(_line('stopped', track, position, duration));
  }

  @override
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack) async {
    events.add('changed:${previousTrack?.id}->${nextTrack?.id}');
  }
}

/// A reporter that throws from every call (after recording it), proving a
/// failing reporter can never break the service or later events.
class _ThrowingReporter extends _RecordingReporter {
  @override
  Future<void> onPlaybackStarted(
      Track track, Duration position, Duration duration) async {
    await super.onPlaybackStarted(track, position, duration);
    throw StateError('report failed');
  }

  @override
  Future<void> onPlaybackPaused(
      Track track, Duration position, Duration duration) async {
    await super.onPlaybackPaused(track, position, duration);
    throw StateError('report failed');
  }
}

/// A reporter whose calls block on [gate] until a test opens it, recording
/// when each call *starts*, so dispatch order under a slow network can be
/// asserted (a pause must never overtake an in-flight progress).
class _GatedReporter extends _RecordingReporter {
  final Completer<void> gate = Completer<void>();
  final List<String> startedCalls = <String>[];

  @override
  Future<void> onPlaybackStarted(
      Track track, Duration position, Duration duration) async {
    startedCalls.add('started');
    await gate.future;
    await super.onPlaybackStarted(track, position, duration);
  }

  @override
  Future<void> onPlaybackPaused(
      Track track, Duration position, Duration duration) async {
    startedCalls.add('paused');
    await gate.future;
    await super.onPlaybackPaused(track, position, duration);
  }
}

Track _track(String id, {Duration duration = Duration.zero}) =>
    Track(id: id, title: id, uri: 'plex:$id', duration: duration);

PlaybackState _state(
  PlaybackStatus status,
  Track? track, {
  Duration position = Duration.zero,
  Duration duration = Duration.zero,
}) =>
    PlaybackState(
      status: status,
      currentTrack: track,
      position: position,
      duration: duration,
    );

/// Drains the microtask chain the listener + dispatch queue run on.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('PlaybackReportingService', () {
    late StreamController<PlaybackState> states;
    late _RecordingReporter reporter;
    late DateTime clock;

    setUp(() {
      states = StreamController<PlaybackState>.broadcast();
      reporter = _RecordingReporter();
      clock = DateTime(2026, 1, 1);
    });

    PlaybackReportingService build({
      Duration progressInterval = const Duration(seconds: 10),
    }) =>
        PlaybackReportingService(
          playbackStates: states.stream,
          reporter: reporter,
          progressInterval: progressInterval,
          now: () => clock,
        );

    test('reports started once when a loading track first plays', () async {
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.loading, a));
      states.add(_state(PlaybackStatus.playing, a,
          duration: const Duration(minutes: 3)));
      await _settle();

      expect(reporter.events, <String>['started:a@0/180000']);
      await service.dispose();
    });

    test('a track that never gets past loading reports nothing', () async {
      final service = build();

      states.add(_state(PlaybackStatus.loading, _track('a')));
      states.add(_state(PlaybackStatus.error, _track('a')));
      await _settle();

      expect(reporter.events, isEmpty);
      await service.dispose();
    });

    test('throttles progress: position ticks inside the interval are dropped',
        () async {
      final service = build();
      final Track a = _track('a');
      const Duration d = Duration(minutes: 3);

      // Settle between emissions so each is observed at its own clock time,
      // the way live position ticks arrive.
      states.add(_state(PlaybackStatus.playing, a, duration: d));
      await _settle();
      // Three ticks within the 10s window: all dropped.
      for (int seconds = 1; seconds <= 3; seconds++) {
        clock = clock.add(const Duration(seconds: 1));
        states.add(_state(PlaybackStatus.playing, a,
            position: Duration(seconds: seconds), duration: d));
        await _settle();
      }
      // Cross the window: exactly one progress goes out.
      clock = clock.add(const Duration(seconds: 7));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 10), duration: d));
      await _settle();
      // And the very next tick is throttled again.
      clock = clock.add(const Duration(seconds: 1));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 11), duration: d));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/180000',
        'progress:a@10000/180000',
      ]);
      await service.dispose();
    });

    test('reports paused and resumed immediately, with positions', () async {
      final service = build();
      final Track a = _track('a');
      const Duration d = Duration(minutes: 3);

      states.add(_state(PlaybackStatus.playing, a, duration: d));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 42), duration: d));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 42), duration: d));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/180000',
        'paused:a@42000/180000',
        'resumed:a@42000/180000',
      ]);
      await service.dispose();
    });

    test('repeated paused states report only one pause', () async {
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 5)));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 5)));
      await _settle();

      expect(reporter.events, <String>['started:a@0/0', 'paused:a@5000/0']);
      await service.dispose();
    });

    test('a pause without a prior start reports nothing', () async {
      final service = build();

      // The suspended-engine (cast handoff) shape: a paused state for a track
      // that was never reported as playing.
      states.add(_state(PlaybackStatus.paused, _track('a')));
      await _settle();

      expect(reporter.events, isEmpty);
      await service.dispose();
    });

    test('stop reports stopped at the last observed position, not zero',
        () async {
      final service = build();
      final Track a = _track('a');
      const Duration d = Duration(minutes: 3);

      states.add(_state(PlaybackStatus.playing, a, duration: d));
      await _settle();
      clock = clock.add(const Duration(seconds: 30));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 30), duration: d));
      // stop() emits a fresh state whose position/duration are zeroed.
      states.add(_state(PlaybackStatus.idle, a));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/180000',
        'progress:a@30000/180000',
        'stopped:a@30000/180000',
      ]);
      await service.dispose();
    });

    test('the queue running out (completed) reports stopped', () async {
      final service = build();
      final Track a = _track('a');
      const Duration d = Duration(minutes: 3);

      states.add(_state(PlaybackStatus.playing, a, duration: d));
      states.add(_state(PlaybackStatus.completed, a, position: d, duration: d));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/180000',
        'stopped:a@180000/180000',
      ]);
      await service.dispose();
    });

    test('a playback error reports stopped (the session must not linger)',
        () async {
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 1)));
      await _settle();
      clock = clock.add(const Duration(seconds: 20));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 20)));
      states.add(_state(PlaybackStatus.error, a));
      await _settle();

      expect(reporter.events.last, 'stopped:a@20000/0');
      await service.dispose();
    });

    test('stopping while paused still reports stopped', () async {
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 9)));
      states.add(_state(PlaybackStatus.idle, a));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/0',
        'paused:a@9000/0',
        'stopped:a@9000/0',
      ]);
      await service.dispose();
    });

    test('playing again after a stop reports a fresh start', () async {
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.idle, a));
      states.add(_state(PlaybackStatus.playing, a));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/0',
        'stopped:a@0/0',
        'started:a@0/0',
      ]);
      await service.dispose();
    });

    test('a track change reports onTrackChanged, then the new start', () async {
      final service = build();
      final Track a = _track('a');
      final Track b = _track('b');

      states.add(_state(PlaybackStatus.playing, a,
          duration: const Duration(minutes: 3)));
      // The controller's natural advance: a loading state for the next track.
      states.add(_state(PlaybackStatus.loading, b));
      states.add(_state(PlaybackStatus.playing, b,
          duration: const Duration(minutes: 2)));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/180000',
        'changed:a->b',
        'started:b@0/120000',
      ]);
      await service.dispose();
    });

    test('a skip while paused still closes the outgoing track', () async {
      final service = build();
      final Track a = _track('a');
      final Track b = _track('b');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 30)));
      states.add(_state(PlaybackStatus.loading, b));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/0',
        'paused:a@30000/0',
        'changed:a->b',
      ]);
      await service.dispose();
    });

    test('a track change from one that never started reports nothing for it',
        () async {
      final service = build();

      states.add(_state(PlaybackStatus.loading, _track('a')));
      states.add(_state(PlaybackStatus.loading, _track('b')));
      states.add(_state(PlaybackStatus.playing, _track('b')));
      await _settle();

      // No session was ever open for `a`, so there is nothing to close.
      expect(reporter.events, <String>['started:b@0/0']);
      await service.dispose();
    });

    test('buffering mid-play is not a pause/resume flap', () async {
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.buffering, a,
          position: const Duration(seconds: 5)));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 5)));
      await _settle();

      expect(reporter.events, <String>['started:a@0/0']);
      await service.dispose();
    });

    test('falls back to the catalog duration when the engine reports none',
        () async {
      final service = build();
      final Track a = _track('a', duration: const Duration(minutes: 4));

      states.add(_state(PlaybackStatus.playing, a));
      await _settle();

      expect(reporter.events, <String>['started:a@0/240000']);
      await service.dispose();
    });

    test('a throwing reporter never breaks later events', () async {
      reporter = _ThrowingReporter();
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 3)));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 3)));
      await _settle();

      // Every event was still attempted, in order, despite each throw.
      expect(reporter.events, <String>[
        'started:a@0/0',
        'paused:a@3000/0',
        'resumed:a@3000/0',
      ]);
      await service.dispose();
    });

    test('dispatches strictly in order even when a report is slow', () async {
      final gated = _GatedReporter();
      reporter = gated;
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 2)));
      await _settle();

      // The slow started call is in flight; the pause must wait behind it.
      expect(gated.startedCalls, <String>['started']);
      gated.gate.complete();
      await _settle();

      expect(gated.startedCalls, <String>['started', 'paused']);
      expect(reporter.events, <String>['started:a@0/0', 'paused:a@2000/0']);
      await service.dispose();
    });

    test('dispose closes an open session with a final stop', () async {
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 1)));
      await _settle();
      clock = clock.add(const Duration(seconds: 15));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 15)));
      await _settle();
      await service.dispose();
      await _settle();

      expect(reporter.events.last, 'stopped:a@15000/0');
    });

    test('dispose with nothing playing reports nothing', () async {
      final service = build();

      states.add(_state(PlaybackStatus.idle, null));
      await _settle();
      await service.dispose();
      await _settle();

      expect(reporter.events, isEmpty);
    });
  });
}
