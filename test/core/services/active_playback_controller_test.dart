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

const _device = CastDevice(id: 'd1', name: 'Living Room');
const _trackA = Track(id: 'a', title: 'Song A', uri: 'jellyfin:a');
const _trackB = Track(id: 'b', title: 'Song B', uri: 'jellyfin:b');

CastState _casting() => const CastState(
      availability: CastAvailability.connected,
      devices: <CastDevice>[_device],
      connectedDevice: _device,
      isCasting: true,
    );

CastState _disconnected() =>
    const CastState(availability: CastAvailability.idle);

/// Lets the test wait for the controller's merged state to reach a condition,
/// without sleeping a fixed amount.
Future<PlaybackState> _waitFor(
  ActivePlaybackController controller,
  bool Function(PlaybackState) predicate,
) async {
  if (predicate(controller.state)) return controller.state;
  return controller.stateStream.firstWhere(predicate).timeout(
        const Duration(seconds: 1),
      );
}

void main() {
  late FakePlaybackController local;
  late FakeCastService cast;

  ActivePlaybackController build() =>
      ActivePlaybackController(local: local, cast: cast);

  setUp(() {
    local = FakePlaybackController(
      initial: const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _trackA,
      ),
    );
    cast = FakeCastService();
  });

  tearDown(() async {
    await cast.dispose();
    await local.dispose();
  });

  group('local output (no cast)', () {
    test('mirrors the local state and routes commands to local', () async {
      final controller = build();
      addTearDown(controller.dispose);

      expect(controller.activeOutput, ActivePlaybackOutput.local);
      expect(controller.state.currentTrack, _trackA);

      await controller.play();
      await controller.pause();
      await controller.seek(const Duration(seconds: 5));

      expect(local.playCount, 1);
      expect(local.pauseCount, 1);
      expect(local.seeks, const <Duration>[Duration(seconds: 5)]);
      // Nothing was sent to the (idle) cast service.
      expect(cast.playCount, 0);
      expect(cast.pauseCount, 0);
      expect(cast.seeks, isEmpty);
    });

    test('follows the local position', () async {
      final controller = build();
      addTearDown(controller.dispose);

      local.emit(const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _trackA,
        position: Duration(seconds: 42),
        duration: Duration(minutes: 3),
      ));

      final state = await _waitFor(
        controller,
        (s) => s.position == const Duration(seconds: 42),
      );
      expect(state.position, const Duration(seconds: 42));
    });
  });

  group('handoff to cast', () {
    test('suspends the local engine and switches output to cast', () async {
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);

      expect(controller.activeOutput, ActivePlaybackOutput.cast);
      expect(local.suspendCount, 1);
    });

    test('play/pause/seek delegate to cast, not local', () async {
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);

      final int localPlaysBefore = local.playCount;
      await controller.play();
      await controller.pause();
      await controller.seek(const Duration(seconds: 20));

      expect(cast.playCount, 1);
      expect(cast.pauseCount, 1);
      expect(cast.seeks, const <Duration>[Duration(seconds: 20)]);
      // The local engine was never told to play/seek while casting.
      expect(local.playCount, localPlaysBefore);
      expect(local.seeks, isEmpty);
    });

    test('merged state follows the cast position/status, keeping the track',
        () async {
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);

      cast.emitPlayback(const CastPlaybackStatus(
        status: PlaybackStatus.paused,
        position: Duration(seconds: 30),
        duration: Duration(minutes: 4),
      ));

      final state = await _waitFor(
        controller,
        (s) => s.position == const Duration(seconds: 30),
      );
      // Position/status/duration come from the receiver…
      expect(state.position, const Duration(seconds: 30));
      expect(state.status, PlaybackStatus.paused);
      expect(state.duration, const Duration(minutes: 4));
      // …while the track stays owned by the local queue.
      expect(state.currentTrack, _trackA);
    });

    test('a local engine error while casting never pulls output back to local',
        () async {
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);
      cast.emitPlayback(const CastPlaybackStatus(
        status: PlaybackStatus.playing,
        position: Duration(seconds: 12),
        duration: Duration(minutes: 3),
      ));
      await _waitFor(controller, (s) => s.status == PlaybackStatus.playing);

      // The silenced local engine reports an error (e.g. a stale stream URL it
      // was never actually playing). It must not change the active output, and
      // the merged state must keep following the receiver — no fall-back to
      // duplicate local playback, no error surfaced over a healthy cast.
      local.emit(const PlaybackState(
        status: PlaybackStatus.error,
        currentTrack: _trackA,
        errorMessage: "Couldn't stream this track.",
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.activeOutput, ActivePlaybackOutput.cast);
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.errorMessage, isNull);
      expect(local.playCount, 0);
    });

    test(
        'skip advances the local queue without local audio; cast re-casts via '
        'the track change', () async {
      local = FakePlaybackController();
      await local.playTracks(const <Track>[_trackA, _trackB]);
      cast = FakeCastService();
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);
      final int playedBefore = local.playedTracks.length;

      await controller.skipToNext();

      expect(controller.state.currentTrack, _trackB);
      // Suspended: skipping never "played" locally.
      expect(local.playedTracks.length, playedBefore);
    });
  });

  group('ending a cast session never surprise-starts local playback', () {
    test('disconnect resumes the local engine paused at the cast position',
        () async {
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);
      cast.emitPlayback(const CastPlaybackStatus(
        status: PlaybackStatus.playing,
        position: Duration(seconds: 50),
        duration: Duration(minutes: 3),
      ));
      await _waitFor(
          controller, (s) => s.position >= const Duration(seconds: 50));

      cast.emit(_disconnected());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.local);

      expect(controller.activeOutput, ActivePlaybackOutput.local);
      expect(local.resumeCount, 1);
      // Resumed PAUSED (never auto-playing) and near where the receiver was.
      expect(local.lastResumePlay, isFalse);
      expect(local.lastResumeAt,
          greaterThanOrEqualTo(const Duration(seconds: 50)));
    });

    test('a dropped receiver session does not auto-play local', () async {
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);
      final int localPlaysBefore = local.playCount;

      // The receiver drops the session (network blip / app closed on the TV).
      cast.emit(_disconnected());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.local);

      // Resumed paused, never played.
      expect(local.lastResumePlay, isFalse);
      expect(local.playCount, localPlaysBefore);
    });
  });

  group('lifecycle', () {
    test('onAppResumed re-syncs from the receiver while casting, never local',
        () async {
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);
      final int localPlaysBefore = local.playCount;

      controller.onAppResumed();

      expect(cast.refreshCount, 1);
      expect(local.playCount, localPlaysBefore);
    });

    test('onAppResumed is a no-op when not casting', () async {
      final controller = build();
      addTearDown(controller.dispose);

      controller.onAppResumed();

      expect(cast.refreshCount, 0);
    });
  });

  group('cast track completion advances per repeat mode', () {
    test('repeat-one replays on the receiver', () async {
      local = FakePlaybackController(
        initial: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _trackA,
          repeatMode: RepeatMode.one,
        ),
      );
      cast = FakeCastService();
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);

      cast.emitPlayback(
          const CastPlaybackStatus(status: PlaybackStatus.completed));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cast.seeks, contains(Duration.zero));
      expect(cast.playCount, greaterThanOrEqualTo(1));
    });

    test('repeat-off advances to the next queued track', () async {
      local = FakePlaybackController();
      await local.playTracks(const <Track>[_trackA, _trackB]);
      cast = FakeCastService();
      final controller = build();
      addTearDown(controller.dispose);

      cast.emit(_casting());
      await _waitFor(controller,
          (_) => controller.activeOutput == ActivePlaybackOutput.cast);

      cast.emitPlayback(
          const CastPlaybackStatus(status: PlaybackStatus.completed));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.state.currentTrack, _trackB);
    });
  });
}
