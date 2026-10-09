import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
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
  ServerPlaybackReporter capture() => this;

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

/// A reporter whose live input (standing in for the signed-in account) can
/// change between a report being queued and being sent, and whose first
/// pause blocks on [gate], so a test can prove each report goes out with the
/// input it was queued under (#838).
class _AccountReporter extends _RecordingReporter {
  _AccountReporter(this.account, this._log, this.gate);

  /// What the live session would read right now.
  String Function() account;
  final List<String> _log;
  final Completer<void> gate;

  /// Each call, with the account it went out to.
  List<String> get sent => _log;

  @override
  ServerPlaybackReporter capture() {
    final String captured = account();
    return _AccountReporter(() => captured, _log, gate);
  }

  @override
  Future<void> onPlaybackPaused(
      Track track, Duration position, Duration duration) async {
    _log.add('paused:${account()}');
    await gate.future;
  }

  @override
  Future<void> onPlaybackStopped(
      Track track, Duration position, Duration duration) async {
    _log.add('stopped:${account()}');
  }
}

/// An engine with just_audio's behaviour where it matters here: a source
/// handed over starts out at its own beginning (just_audio publishes the new
/// source's position, zero, the moment setUrl is called), keeps the playing
/// flag it had, and takes a server round trip to open; a seek publishes where
/// it went. A stream that drops surfaces as an error on the event stream, as
/// ExoPlayer's "Source error" does.
class _StreamingEngine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  static const Duration length = Duration(minutes: 3);
  static const Duration openTime = Duration(milliseconds: 400);

  bool _playing = false;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    _positions.add(initialPosition ?? Duration.zero);
    _states.add(PlayerState(_playing, ProcessingState.loading));
    await Future<void>.delayed(openTime);
    _durations.add(length);
    _states.add(PlayerState(_playing, ProcessingState.ready));
    return length;
  }

  @override
  Future<void> play() async {
    _playing = true;
    _states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _states.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _positions.add(position ?? Duration.zero);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    _playing = false;
    _states.add(PlayerState(false, ProcessingState.idle));
  }

  @override
  Future<void> dispose() async {}

  void playsOnTo(Duration position) => _positions.add(position);

  void dropsStream() => _events.addError(
      PlayerException(0, 'Source error', <String, dynamic>{}),
      StackTrace.empty);

  void ends() => _states.add(PlayerState(_playing, ProcessingState.completed));
}

class _StreamResolver implements PlayableUriResolver {
  int _resolves = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async => ResolvedPlayable(
        Uri.parse('https://music.example/${track.id}?n=${++_resolves}'),
        PlaybackSource.streamingDirect,
      );
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

    test('each repeat-one pass is reported as a play of its own', () async {
      // Repeat-one replays the track in place: the controller seeks it back
      // to the start and plays on, publishing no track change and no
      // completed status, only the position coming back to zero. The server
      // has to hear each pass end, or it counts (and scrobbles) none of them.
      final service = build(progressInterval: const Duration(hours: 1));
      final Track a = _track('a');
      final Track b = _track('b');
      const Duration d = Duration(minutes: 3);

      states.add(_state(PlaybackStatus.playing, a, duration: d));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(minutes: 1), duration: d));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(minutes: 2, seconds: 59, milliseconds: 800),
          duration: d));
      // The end: the same track again from the top.
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(milliseconds: 250), duration: d));
      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(seconds: 40), duration: d));
      // Then on to the next track partway through the second pass.
      states.add(_state(PlaybackStatus.loading, b));
      await _settle();

      expect(reporter.events, <String>[
        'started:a@0/180000',
        'stopped:a@179800/180000',
        'started:a@250/180000',
        'changed:a->b',
      ]);
      await service.dispose();
    });

    test('a seek back within the track is not a new play', () async {
      final service = build(progressInterval: const Duration(hours: 1));
      final Track a = _track('a');
      const Duration d = Duration(minutes: 3);

      states.add(_state(PlaybackStatus.playing, a,
          position: const Duration(minutes: 2), duration: d));
      // Back to the very start, but the track never reached its end.
      states.add(_state(PlaybackStatus.playing, a, duration: d));
      await _settle();

      expect(reporter.events, <String>['started:a@120000/180000']);
      await service.dispose();
    });

    test('a same-id provider fallback is reported as a track change', () async {
      // A preferred copy fails and playback falls back to another provider's
      // copy that shares the bare id. The reporting identity is the uri, so the
      // failed copy's session is closed (onTrackChanged) and the copy actually
      // playing opens its own start — distinguished here by its duration.
      final service = build();
      const Track jelly = Track(id: '101', title: 'Alpha', uri: 'jellyfin:101');
      const Track sub = Track(id: '101', title: 'Beta', uri: 'subsonic:101');

      states.add(_state(PlaybackStatus.playing, jelly,
          duration: const Duration(minutes: 3)));
      states.add(_state(PlaybackStatus.playing, sub,
          duration: const Duration(minutes: 2)));
      await _settle();

      expect(reporter.events, <String>[
        'started:101@0/180000', // the failed-preferred jellyfin copy (3 min)
        'changed:101->101',
        'started:101@0/120000', // the subsonic copy actually playing (2 min)
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

    test(
        'a report waiting its turn goes out to the account it was queued '
        'for, even once that account can no longer be read', () async {
      String live = 'alice';
      final _AccountReporter accounts = _AccountReporter(
        () => live == 'gone' ? throw StateError('container disposed') : live,
        <String>[],
        Completer<void>(),
      );
      reporter = accounts;
      final service = build();
      final Track a = _track('a');

      states.add(_state(PlaybackStatus.playing, a));
      states.add(_state(PlaybackStatus.paused, a,
          position: const Duration(seconds: 4)));
      await _settle();
      expect(accounts.sent, <String>['paused:alice']);

      // The listener quits while the server is still answering the pause:
      // the stop is queued behind it, then everything it read goes away.
      await service.dispose();
      live = 'gone';
      accounts.gate.complete();
      await service.idle;

      expect(accounts.sent, <String>['paused:alice', 'stopped:alice']);
    });

    test('dispose does not wait on the network, idle does', () async {
      final _GatedReporter gated = _GatedReporter();
      reporter = gated;
      final service = build();
      final Track a = _track('a');
      states.add(_state(PlaybackStatus.playing, a));
      await _settle();
      expect(gated.startedCalls, <String>['started']);

      bool idle = false;
      await service.dispose();
      unawaited(service.idle.then((_) => idle = true));
      await _settle();
      expect(idle, isFalse);

      gated.gate.complete();
      await _settle();
      await _settle();
      expect(idle, isTrue);
      expect(reporter.events, <String>['started:a@0/0', 'stopped:a@0/0']);
    });

    test('a second dispose queues no second stop', () async {
      final service = build();
      final Track a = _track('a');
      states.add(_state(PlaybackStatus.playing, a));
      await _settle();

      await service.dispose();
      await service.dispose();
      await service.idle;

      expect(
        reporter.events.where((String e) => e.startsWith('stopped')),
        hasLength(1),
      );
    });

    test('a reporter that can no longer be read drops the report quietly',
        () async {
      final _AccountReporter accounts = _AccountReporter(
        () => throw StateError('container disposed'),
        <String>[],
        Completer<void>(),
      );
      reporter = accounts;
      final service = build();

      states.add(_state(PlaybackStatus.playing, _track('a')));
      await _settle();
      await service.dispose();
      await service.idle;

      expect(accounts.sent, isEmpty);
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

  group('with the real player', () {
    // A one-song queue played to its end, then Play to hear it again: the
    // controller starts the song over (as it does after Stop at the end, or
    // a seek back into a finished queue). That is a new play; the one before
    // it was already reported stopped at its end.
    // A widget test only for its fake clock.
    testWidgets('playing a song again after it ended counts it once more',
        (WidgetTester tester) async {
      final _StreamingEngine engine = _StreamingEngine();
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: _StreamResolver(),
      );
      final _RecordingReporter reporter = _RecordingReporter();
      final PlaybackReportingService service = PlaybackReportingService(
        playbackStates: controller.stateStream,
        reporter: reporter,
        progressInterval: const Duration(hours: 1),
      );
      final Track a = _track('a', duration: _StreamingEngine.length);

      unawaited(controller.playTracks(<Track>[a]));
      await tester.pump(const Duration(seconds: 1));
      expect(controller.state.status, PlaybackStatus.playing);
      engine.playsOnTo(const Duration(minutes: 2, seconds: 59));
      await tester.pump(const Duration(milliseconds: 500));
      engine.ends();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.state.status, PlaybackStatus.completed);

      // The listener plays it again.
      unawaited(controller.play());
      await tester.pump(const Duration(seconds: 1));
      expect(controller.state.status, PlaybackStatus.playing);
      engine.playsOnTo(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      engine.playsOnTo(const Duration(seconds: 1, milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        reporter.events,
        <String>[
          'started:a@0/180000',
          'stopped:a@179000/180000',
          'started:a@0/180000',
        ],
        reason: 'the first play was reported stopped once, at its end; a '
            'second stop there counts (and scrobbles) it again',
      );

      unawaited(service.dispose());
      unawaited(controller.dispose());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
