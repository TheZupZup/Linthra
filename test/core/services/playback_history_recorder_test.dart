import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_history.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_history_recorder.dart';

Track _track(String id) => Track(
      id: id,
      title: 'Song $id',
      uri: 'jellyfin:$id',
      duration: const Duration(minutes: 3),
    );

PlaybackState _playing(
  Track track, {
  Duration position = Duration.zero,
  Duration duration = const Duration(minutes: 3),
  PlaybackStatus status = PlaybackStatus.playing,
}) =>
    PlaybackState(
      status: status,
      currentTrack: track,
      position: position,
      duration: duration,
    );

/// What the recorder reported, in order.
typedef _Played = ({String uri, PlaybackHistoryOutcome outcome});

void main() {
  late List<_Played> played;
  late PlaybackHistoryRecorder recorder;

  setUp(() {
    played = <_Played>[];
    recorder = PlaybackHistoryRecorder(
      states: const Stream<PlaybackState>.empty(),
      onPlayed: (Track track, PlaybackHistoryOutcome outcome, DateTime _) =>
          played.add((uri: track.uri, outcome: outcome)),
      now: () => DateTime.utc(2026, 1, 1),
    );
  });

  group('completed vs skipped', () {
    test('a track played to its end is completed', () {
      recorder.onState(_playing(_track('1')));
      recorder.onState(
        _playing(_track('1'), position: const Duration(minutes: 3)),
      );
      recorder.onState(_playing(_track('2')));

      expect(played, <_Played>[
        (uri: 'jellyfin:1', outcome: PlaybackHistoryOutcome.completed),
      ]);
    });

    test('stopping a beat short still counts as completed', () {
      // Engines stop reporting a moment before the true end.
      recorder.onState(_playing(_track('1')));
      recorder.onState(
        _playing(
          _track('1'),
          position: const Duration(minutes: 2, seconds: 59),
        ),
      );
      recorder.onState(_playing(_track('2')));

      expect(played.single.outcome, PlaybackHistoryOutcome.completed);
    });

    test('a track abandoned in the middle is a skip', () {
      recorder.onState(_playing(_track('1')));
      recorder.onState(
        _playing(_track('1'), position: const Duration(seconds: 30)),
      );
      recorder.onState(_playing(_track('2')));

      expect(played.single.outcome, PlaybackHistoryOutcome.skipped);
    });

    test('seeking back from the end does not turn a finish into a skip', () {
      recorder.onState(_playing(_track('1')));
      recorder.onState(
        _playing(_track('1'), position: const Duration(minutes: 3)),
      );
      // The engine reports position 0 again as the next source loads.
      recorder.onState(_playing(_track('1')));
      recorder.onState(_playing(_track('2')));

      expect(played.single.outcome, PlaybackHistoryOutcome.completed);
    });

    test('the last track of a queue is recorded on the completed status', () {
      // Nothing follows it, so there is no track change to observe.
      recorder.onState(_playing(_track('1')));
      recorder.onState(
        _playing(
          _track('1'),
          position: const Duration(minutes: 3),
          status: PlaybackStatus.completed,
        ),
      );

      expect(played, <_Played>[
        (uri: 'jellyfin:1', outcome: PlaybackHistoryOutcome.completed),
      ]);
    });

    test('a completed track is never recorded twice', () {
      recorder.onState(_playing(_track('1')));
      recorder.onState(
        _playing(_track('1'), status: PlaybackStatus.completed),
      );
      recorder.onState(
        _playing(_track('1'), status: PlaybackStatus.completed),
      );
      recorder.onState(_playing(_track('2')));

      expect(played.length, 1);
    });
  });

  group('what never earns an entry', () {
    test('a track that failed to load is not "recently played"', () {
      recorder.onState(
        _playing(_track('1'), status: PlaybackStatus.loading),
      );
      recorder.onState(_playing(_track('1'), status: PlaybackStatus.error));
      recorder.onState(_playing(_track('2')));

      expect(played, isEmpty);
    });

    test('an idle stream records nothing', () {
      recorder.onState(PlaybackState.idle);
      recorder.onState(PlaybackState.idle);
      expect(played, isEmpty);
    });

    test('a repeat-one loop keeps one entry, not one per pass', () {
      recorder.onState(_playing(_track('1')));
      for (int i = 0; i < 5; i++) {
        recorder.onState(
          _playing(_track('1'), position: const Duration(minutes: 3)),
        );
        recorder.onState(_playing(_track('1')));
      }
      recorder.onState(_playing(_track('2')));

      expect(played.length, 1);
    });
  });

  group('lifecycle', () {
    test('every track of a queue lands in order', () {
      for (final String id in <String>['1', '2', '3']) {
        recorder.onState(_playing(_track(id)));
        recorder.onState(
          _playing(_track(id), position: const Duration(seconds: 10)),
        );
      }
      recorder.onState(_playing(_track('4')));

      expect(
        <String>[for (final _Played p in played) p.uri],
        <String>['jellyfin:1', 'jellyfin:2', 'jellyfin:3'],
      );
    });

    test('start is idempotent, so nothing is ever recorded twice', () async {
      final StreamController<PlaybackState> states =
          StreamController<PlaybackState>.broadcast();
      addTearDown(states.close);
      final List<_Played> doubled = <_Played>[];
      final PlaybackHistoryRecorder streamed = PlaybackHistoryRecorder(
        states: states.stream,
        onPlayed: (Track track, PlaybackHistoryOutcome outcome, DateTime _) =>
            doubled.add((uri: track.uri, outcome: outcome)),
      );
      addTearDown(streamed.dispose);

      streamed.start();
      streamed.start();
      states.add(_playing(_track('1')));
      states.add(_playing(_track('2')));
      await Future<void>.delayed(Duration.zero);

      expect(doubled.length, 1);
    });

    test('disposing stops observing', () async {
      final StreamController<PlaybackState> states =
          StreamController<PlaybackState>.broadcast();
      addTearDown(states.close);
      final List<_Played> after = <_Played>[];
      final PlaybackHistoryRecorder streamed = PlaybackHistoryRecorder(
        states: states.stream,
        onPlayed: (Track track, PlaybackHistoryOutcome outcome, DateTime _) =>
            after.add((uri: track.uri, outcome: outcome)),
      )..start();

      states.add(_playing(_track('1')));
      await Future<void>.delayed(Duration.zero);
      await streamed.dispose();
      states.add(_playing(_track('2')));
      await Future<void>.delayed(Duration.zero);

      expect(after, isEmpty);
    });
  });
}
