// A cast receiver that reports "finished" more than once for one track.
//
// A receiver can send the same finished status more than once: a status
// refresh when the app comes back to the foreground, or another status push
// before the next track has loaded. ActivePlaybackController advances the
// queue on a cast completion the way local playback would, so each repeat that
// got through would skip a whole track the listener never heard (or restart
// the queue, or replay, twice). One track ending is one advance; a later track
// ending, after the receiver has played again, is the next one.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/active_playback_output.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/active_playback_controller.dart';

import '../../features/player/cast/fake_cast_service.dart';
import '../../features/player/fake_playback_controller.dart';

const CastDevice _device = CastDevice(id: 'd1', name: 'Living Room');
const Track _a = Track(id: 'a', title: 'Song A', uri: 'jellyfin:a');
const Track _b = Track(id: 'b', title: 'Song B', uri: 'jellyfin:b');
const Track _c = Track(id: 'c', title: 'Song C', uri: 'jellyfin:c');

const CastState _casting = CastState(
  availability: CastAvailability.connected,
  devices: <CastDevice>[_device],
  connectedDevice: _device,
  isCasting: true,
);

const CastPlaybackStatus _finished =
    CastPlaybackStatus(status: PlaybackStatus.completed);
const CastPlaybackStatus _playing = CastPlaybackStatus(
  status: PlaybackStatus.playing,
  duration: Duration(minutes: 3),
);

/// Lets the broadcast cast/local streams deliver and the unawaited queue
/// actions they trigger run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakePlaybackController local;
  late FakeCastService cast;

  setUp(() {
    local = FakePlaybackController();
    cast = FakeCastService();
  });

  tearDown(() async {
    await cast.dispose();
    await local.dispose();
  });

  /// An [ActivePlaybackController] over [local] that has handed off to the
  /// receiver.
  Future<ActivePlaybackController> casting() async {
    final ActivePlaybackController controller =
        ActivePlaybackController(local: local, cast: cast);
    addTearDown(controller.dispose);
    cast.emit(_casting);
    await _settle();
    expect(controller.activeOutput, ActivePlaybackOutput.cast);
    return controller;
  }

  test('a repeated "finished" advances the queue once', () async {
    await local.playTracks(const <Track>[_a, _b, _c]);
    final ActivePlaybackController controller = await casting();

    cast.emitPlayback(_finished);
    cast.emitPlayback(_finished);
    await _settle();

    expect(local.skipCount, 1, reason: 'one track ended, so one advance');
    expect(controller.state.currentTrack, _b);
  });

  test('the next track finishing after it played advances again', () async {
    await local.playTracks(const <Track>[_a, _b, _c]);
    final ActivePlaybackController controller = await casting();

    cast.emitPlayback(_finished);
    cast.emitPlayback(_finished);
    await _settle();
    // The receiver loads B and plays it through.
    cast.emitPlayback(_playing);
    cast.emitPlayback(_finished);
    await _settle();

    expect(local.skipCount, 2);
    expect(controller.state.currentTrack, _c);
  });

  test(
      'a repeated "finished" on the last track restarts a repeat-all queue '
      'once', () async {
    await local.playTracks(const <Track>[_a, _b], startIndex: 1);
    local.setRepeatMode(RepeatMode.all);
    final ActivePlaybackController controller = await casting();

    cast.emitPlayback(_finished);
    cast.emitPlayback(_finished);
    await _settle();

    expect(local.restartQueueCount, 1);
    expect(local.skipCount, 0);
    expect(controller.state.currentTrack, _a);
  });

  test('a repeated "finished" under repeat-one replays once', () async {
    await local.playTracks(const <Track>[_a, _b]);
    local.setRepeatMode(RepeatMode.one);
    await casting();

    cast.emitPlayback(_finished);
    cast.emitPlayback(_finished);
    await _settle();

    expect(cast.seeks, const <Duration>[Duration.zero]);
    expect(cast.playCount, 1);
    expect(local.skipCount, 0);
  });
}
