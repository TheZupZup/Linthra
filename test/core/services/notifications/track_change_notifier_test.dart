import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/notifications/desktop_notifier.dart';
import 'package:linthra/core/services/notifications/track_change_notifier.dart';

Track _track(String id) => Track(
      id: id,
      title: 'Song $id',
      uri: 'jellyfin:$id',
      artistName: 'Artist $id',
      duration: const Duration(minutes: 3),
    );

PlaybackState _state(
  Track? track, {
  PlaybackStatus status = PlaybackStatus.playing,
  Duration position = Duration.zero,
}) =>
    PlaybackState(
      status: status,
      currentTrack: track,
      position: position,
      duration: const Duration(minutes: 3),
    );

/// A notifier that records what it was asked to show, and can refuse.
class _RecordingNotifier implements DesktopNotifier {
  _RecordingNotifier({this.isSupported = true, this.failWith});

  @override
  final bool isSupported;

  /// Thrown by every [show] when set: a daemon that is not there.
  final Object? failWith;

  final List<DesktopNotification> shown = <DesktopNotification>[];
  int disposeCount = 0;

  @override
  Future<void> show(DesktopNotification notification) async {
    shown.add(notification);
    final Object? failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<void> dispose() async => disposeCount++;
}

class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;

  /// Runs the scheduled callback, the way real time would.
  void fire() {
    if (cancelled) return;
    _callback();
  }
}

void main() {
  late _RecordingNotifier notifier;
  late List<_FakeTimer> timers;
  late Duration clock;
  late bool enabled;
  late TrackChangeNotifier observer;

  /// The titles announced, in order: enough to say *which* track each
  /// notification was for.
  List<String> announced() =>
      notifier.shown.map((DesktopNotification n) => n.title).toList();

  TrackChangeNotifier build({
    _RecordingNotifier? recording,
    Duration minInterval = const Duration(seconds: 5),
  }) {
    notifier = recording ?? _RecordingNotifier();
    return observer = TrackChangeNotifier(
      states: const Stream<PlaybackState>.empty(),
      notifier: notifier,
      enabled: () => enabled,
      build: (Track track) => DesktopNotification(
        title: track.title,
        body: track.artistName ?? '',
      ),
      minInterval: minInterval,
      elapsed: () => clock,
      createTimer: (Duration delay, void Function() callback) {
        final _FakeTimer timer = _FakeTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
  }

  setUp(() {
    timers = <_FakeTimer>[];
    clock = Duration.zero;
    enabled = true;
    build();
  });

  tearDown(() => observer.dispose());

  group('a real track change', () {
    test('announces the track that starts playing', () {
      observer.onState(_state(_track('1')));

      expect(announced(), <String>['Song 1']);
      expect(notifier.shown.single.body, 'Artist 1');
    });

    test('announces the next track when it starts playing', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(minutes: 3);
      observer.onState(_state(_track('2')));

      expect(announced(), <String>['Song 1', 'Song 2']);
    });

    test('position updates on the same track say nothing', () {
      observer.onState(_state(_track('1')));
      for (int second = 1; second <= 30; second++) {
        clock += const Duration(seconds: 1);
        observer.onState(
          _state(_track('1'), position: Duration(seconds: second)),
        );
      }

      expect(announced(), <String>['Song 1']);
    });

    test('a pause and a resume say nothing', () {
      final Track track = _track('1');
      observer.onState(_state(track));
      clock += const Duration(minutes: 1);
      observer.onState(_state(track, status: PlaybackStatus.paused));
      clock += const Duration(minutes: 1);
      observer.onState(_state(track));

      expect(announced(), <String>['Song 1']);
    });

    test('the same track state pushed twice does not announce twice', () {
      final PlaybackState state = _state(_track('1'));
      observer.onState(state);
      observer.onState(state);
      clock += const Duration(minutes: 3);
      observer.onState(state);

      expect(announced(), <String>['Song 1']);
    });

    test('a queue rebuild carrying the same song says nothing', () {
      // A fresh Track object for the same song: what a re-queue, a favourite
      // toggle or a catalog refresh produces.
      observer.onState(_state(_track('1')));
      clock += const Duration(minutes: 1);
      observer.onState(_state(_track('1')));

      expect(announced(), <String>['Song 1']);
    });

    test('repeat-one starting the same song again says nothing', () {
      final Track track = _track('1');
      observer.onState(_state(track, position: const Duration(minutes: 2)));
      clock += const Duration(minutes: 1);
      // The replay: same track, back at the beginning.
      observer.onState(_state(track));

      expect(announced(), <String>['Song 1']);
    });

    test('a track that starts while buffering is announced', () {
      // Buffering means the engine is working toward sound on this track,
      // which is as much a track change as reaching playing.
      observer.onState(_state(_track('1'), status: PlaybackStatus.buffering));

      expect(announced(), <String>['Song 1']);
    });

    test('a reconnect mid-stream says nothing', () {
      final Track track = _track('1');
      observer.onState(_state(track));
      clock += const Duration(minutes: 1);
      observer.onState(
        _state(track, status: PlaybackStatus.reconnecting),
      );

      expect(announced(), <String>['Song 1']);
    });
  });

  group('nothing is playing', () {
    test('a track that is only loading is not announced', () {
      observer.onState(_state(_track('1'), status: PlaybackStatus.loading));

      expect(announced(), isEmpty);
    });

    test('a queue restored paused is not announced', () {
      observer.onState(_state(_track('1'), status: PlaybackStatus.paused));

      expect(announced(), isEmpty);
    });

    test('a load that errored is not announced', () {
      observer.onState(_state(_track('1'), status: PlaybackStatus.error));

      expect(announced(), isEmpty);
    });

    test('an empty player is not announced', () {
      observer.onState(_state(null, status: PlaybackStatus.idle));

      expect(announced(), isEmpty);
    });
  });

  group('the preference', () {
    test('off announces nothing at all', () {
      enabled = false;
      observer.onState(_state(_track('1')));
      clock += const Duration(minutes: 3);
      observer.onState(_state(_track('2')));

      expect(announced(), isEmpty);
      expect(timers, isEmpty);
    });

    test('turning it on mid-track stays quiet until the next change', () {
      enabled = false;
      observer.onState(_state(_track('1')));
      enabled = true;
      clock += const Duration(seconds: 30);
      // Still the same song, just a later position.
      observer.onState(
        _state(_track('1'), position: const Duration(seconds: 30)),
      );

      expect(announced(), isEmpty);

      clock += const Duration(minutes: 3);
      observer.onState(_state(_track('2')));
      expect(announced(), <String>['Song 2']);
    });

    test('turning it off while a burst waits cancels the pending one', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2')));
      enabled = false;
      timers.single.fire();

      expect(announced(), <String>['Song 1']);
    });
  });

  group('rapid skipping', () {
    test('a burst produces one notification, for the track landed on', () {
      observer.onState(_state(_track('1')));
      for (final String id in <String>['2', '3', '4', '5']) {
        clock += const Duration(milliseconds: 400);
        observer.onState(_state(_track(id)));
      }

      // Nothing beyond the first has reached the daemon yet, and the whole
      // burst shares one timer.
      expect(announced(), <String>['Song 1']);
      expect(timers, hasLength(1));

      timers.single.fire();
      expect(announced(), <String>['Song 1', 'Song 5']);
    });

    test('the wait is only the rest of the window', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 4);
      observer.onState(_state(_track('2')));

      expect(timers.single.delay, const Duration(seconds: 1));
    });

    test('a change past the window announces immediately', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 5);
      observer.onState(_state(_track('2')));

      expect(announced(), <String>['Song 1', 'Song 2']);
      expect(timers, isEmpty);
    });

    test('the window restarts from the coalesced notification', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2')));
      timers.single.fire();
      expect(announced(), <String>['Song 1', 'Song 2']);

      // One second after the coalesced one: still inside the window.
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('3')));
      expect(announced(), <String>['Song 1', 'Song 2']);
      expect(timers, hasLength(2));
    });

    test('skipping back to the announced track drops the waiting one', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2')));
      // Straight back to the song they were already told about.
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('1')));
      timers.single.fire();

      // Announcing "Song 2" here would name the track they skipped away from.
      expect(announced(), <String>['Song 1']);
    });

    test('pausing inside the window drops the waiting announcement', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2'), status: PlaybackStatus.paused));
      timers.single.fire();

      expect(announced(), <String>['Song 1']);

      // Still announced properly once it really is playing again.
      clock += const Duration(seconds: 10);
      observer.onState(_state(_track('2')));
      expect(announced(), <String>['Song 1', 'Song 2']);
    });

    test('the queue emptying inside the window drops it too', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(null, status: PlaybackStatus.idle));
      timers.single.fire();

      expect(announced(), <String>['Song 1']);
    });

    test('a track still playing when the window closes is announced', () {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2')));
      // Ordinary position ticks on the pending track keep it valid.
      for (int second = 2; second <= 4; second++) {
        clock += const Duration(seconds: 1);
        observer.onState(
          _state(_track('2'), position: Duration(seconds: second)),
        );
      }
      timers.single.fire();

      expect(announced(), <String>['Song 1', 'Song 2']);
    });

    test('a clock that jumps backwards never buys silence', () {
      observer.onState(_state(_track('1')));
      // What a wall clock does on an NTP correction. The real source is
      // monotonic, so this is the guard rather than the normal path: the
      // window must read as passed, not as an hour of negative gap.
      clock -= const Duration(hours: 1);
      observer.onState(_state(_track('2')));

      expect(announced(), <String>['Song 1', 'Song 2']);
      expect(timers, isEmpty);
    });

    test('dispose drops a pending announcement', () async {
      observer.onState(_state(_track('1')));
      clock += const Duration(seconds: 1);
      observer.onState(_state(_track('2')));

      await observer.dispose();
      expect(timers.single.cancelled, isTrue);
      timers.single.fire();

      expect(announced(), <String>['Song 1']);
    });
  });

  group('a notification backend that fails', () {
    test('never reaches the caller, and the next track is still tried',
        () async {
      build(recording: _RecordingNotifier(failWith: StateError('no daemon')));

      expect(() => observer.onState(_state(_track('1'))), returnsNormally);
      clock += const Duration(minutes: 3);
      expect(() => observer.onState(_state(_track('2'))), returnsNormally);

      // Both were attempted; both failures were swallowed.
      await Future<void>.delayed(Duration.zero);
      expect(announced(), <String>['Song 1', 'Song 2']);
    });

    test('a failing notifier does not stop the state stream', () async {
      final StreamController<PlaybackState> states =
          StreamController<PlaybackState>();
      addTearDown(states.close);
      final _RecordingNotifier failing =
          _RecordingNotifier(failWith: StateError('no daemon'));
      final TrackChangeNotifier live = TrackChangeNotifier(
        states: states.stream,
        notifier: failing,
        enabled: () => true,
        build: (Track track) => DesktopNotification(title: track.title),
        elapsed: () => clock,
      );
      addTearDown(live.dispose);
      live.start();

      states.add(_state(_track('1')));
      await Future<void>.delayed(Duration.zero);
      clock += const Duration(minutes: 3);
      states.add(_state(_track('2')));
      await Future<void>.delayed(Duration.zero);

      expect(
        failing.shown.map((DesktopNotification n) => n.title),
        <String>['Song 1', 'Song 2'],
      );
    });
  });

  group('a platform with no notifications', () {
    test('an unsupported notifier is never asked to show anything', () {
      build(recording: _RecordingNotifier(isSupported: false));

      observer.onState(_state(_track('1')));
      clock += const Duration(minutes: 3);
      observer.onState(_state(_track('2')));

      expect(announced(), isEmpty);
    });
  });

  group('start', () {
    test('is idempotent, so one track change announces once', () async {
      final StreamController<PlaybackState> states =
          StreamController<PlaybackState>.broadcast();
      addTearDown(states.close);
      final _RecordingNotifier recording = _RecordingNotifier();
      final TrackChangeNotifier live = TrackChangeNotifier(
        states: states.stream,
        notifier: recording,
        enabled: () => true,
        build: (Track track) => DesktopNotification(title: track.title),
        elapsed: () => clock,
      );
      addTearDown(live.dispose);
      live.start();
      live.start();

      states.add(_state(_track('1')));
      await Future<void>.delayed(Duration.zero);

      expect(recording.shown, hasLength(1));
    });
  });
}
