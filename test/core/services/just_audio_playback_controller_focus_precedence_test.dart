// What wins when an audio-focus action meets something more definite.
//
// A focus loss or regain is queued on the controller's serialized transport
// chain, or waits out a debounce first. Anything the listener (or the
// hardware) does in that window has the last word: headphones pulled out
// during a call, a Pause or Stop pressed in the same instant the call ends, a
// Play pressed while a loss is still pending, and a cast taking the audio
// over. None of them may be undone by the focus action that was already on
// its way, and none may leave a resume armed for a later regain to act on.
//
// The volume side has the same rule: the regain or unduck that ends a duck
// puts back the level the listener chose, not full volume.
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// A fake engine that records, in order, every transport call the controller
/// makes (`play`, `pause`, `stop`), every source it opens and every volume it
/// sets. No platform channel is touched, so the focus events are pumped
/// straight into [JustAudioPlaybackController.onAudioInterruption].
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<String> transport = <String>[];
  final List<String> loadedUrls = <String>[];
  final List<double> volumes = <double>[];

  int get playCalls => transport.where((String t) => t == 'play').length;
  int get pauseCalls => transport.where((String t) => t == 'pause').length;

  @override
  Stream<PlayerState> get playerStateStream =>
      const Stream<PlayerState>.empty();
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      const Stream<PlaybackEvent>.empty();

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    loadedUrls.add(url);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> play() async => transport.add('play');
  @override
  Future<void> pause() async => transport.add('pause');
  @override
  Future<void> stop() async => transport.add('stop');
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

class _Resolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async => ResolvedPlayable(
        Uri.parse('https://host/stream/${track.id}'),
        PlaybackSource.streamingDirect,
      );
}

const Track _a = Track(id: 'a', title: 'A', uri: 'jellyfin:a');
const Track _b = Track(id: 'b', title: 'B', uri: 'jellyfin:b');

/// The transient-loss debounce, run on the test's fake clock.
const Duration _debounce = Duration(milliseconds: 10);

/// Fake time past [_debounce], so a scheduled transient-loss pause has fired.
const Duration _pastDebounce = Duration(milliseconds: 40);

AudioInterruptionEvent _begin(AudioInterruptionType type) =>
    AudioInterruptionEvent(true, type);
AudioInterruptionEvent _end(AudioInterruptionType type) =>
    AudioInterruptionEvent(false, type);

void main() {
  /// A controller playing [_a] with [_b] next, the engine reporting it plays.
  Future<({JustAudioPlaybackController controller, _RecordingPlayer player})>
      playing(WidgetTester tester) async {
    final _RecordingPlayer player = _RecordingPlayer();
    final JustAudioPlaybackController controller =
        JustAudioPlaybackController(player: player, resolver: _Resolver())
          ..focusPauseDebounce = _debounce;
    addTearDown(controller.dispose);
    await controller.playTracks(<Track>[_a, _b]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    expect(player.transport, <String>['play']);
    expect(controller.state.status, PlaybackStatus.playing);
    return (controller: controller, player: player);
  }

  /// [playing], then a call that outlasts the debounce: the engine is
  /// paused, the resume is armed and the foreground hold is up.
  Future<({JustAudioPlaybackController controller, _RecordingPlayer player})>
      pausedForACall(WidgetTester tester) async {
    final setup = await playing(tester);
    setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
    await tester.pump(_pastDebounce);
    setup.controller
        .handleEngineState(PlayerState(false, ProcessingState.ready));
    expect(setup.player.transport, <String>['play', 'pause']);
    expect(setup.controller.state.interruptedByTransientFocus, isTrue);
    return setup;
  }

  group('headphones unplugged during a transient focus loss', () {
    testWidgets(
        'after the call paused, cancel its resume: the regain stays silent',
        (WidgetTester tester) async {
      final setup = await pausedForACall(tester);

      setup.controller.onBecomingNoisyForTesting();
      await tester.pump();

      expect(setup.controller.state.interruptedByTransientFocus, isFalse,
          reason: 'nothing is left to resume, so nothing holds the service');

      // The call ends with the headphones still out.
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await tester.pump();

      expect(setup.player.playCalls, 1,
          reason: 'the regain must not start the speaker');
      expect(setup.player.transport.last, 'pause');
    });

    testWidgets('inside the debounce window, pause once and never resume',
        (WidgetTester tester) async {
      final setup = await playing(tester);

      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      // Pulled out before the debounce has paused for the call.
      setup.controller.onBecomingNoisyForTesting();
      await tester.pump();
      expect(setup.player.pauseCalls, 1, reason: 'the unplug pauses at once');

      // When the debounce would have fired.
      await tester.pump(_pastDebounce);
      expect(setup.player.pauseCalls, 1,
          reason: 'the cancelled debounce must not pause a second time');

      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await tester.pump();

      expect(setup.player.playCalls, 1);
      expect(setup.player.transport.last, 'pause');
      expect(setup.controller.state.interruptedByTransientFocus, isFalse);
    });

    testWidgets(
        'while ducked, lift the duck so the next Play is at full volume',
        (WidgetTester tester) async {
      final setup = await playing(tester);
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await tester.pump();
      expect(setup.controller.isDuckedForTesting, isTrue);
      expect(setup.player.volumes.last, lessThan(1.0));

      setup.controller.onBecomingNoisyForTesting();
      await tester.pump();

      expect(setup.controller.isDuckedForTesting, isFalse);
      expect(setup.player.volumes.last, 1.0,
          reason: 'a duck must not outlive the pause it was cut short by');
      expect(setup.player.transport.last, 'pause');
    });
  });

  // The listener's own transport is the latest intent. A focus action already
  // queued on the chain (or a debounce still pending) is superseded by it,
  // even when both land in the same turn.
  group('an explicit transport wins over a queued focus action', () {
    testWidgets('a Pause in the same turn as the regain keeps it paused',
        (WidgetTester tester) async {
      final setup = await pausedForACall(tester);

      // The call ends, and the listener presses Pause before the queued
      // resume has run.
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await setup.controller.pause();
      await tester.pump();

      expect(setup.player.playCalls, 1,
          reason: 'the superseded resume must not run after the pause');
      expect(setup.player.transport.last, 'pause');
      expect(setup.controller.state.interruptedByTransientFocus, isFalse);
      expect(setup.controller.state.playWhenReady, isFalse);
    });

    testWidgets('a Stop in the same turn as the regain stays stopped',
        (WidgetTester tester) async {
      final setup = await pausedForACall(tester);

      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await setup.controller.stop();
      await tester.pump();

      expect(setup.player.playCalls, 1,
          reason: 'the superseded resume must not run after the stop');
      expect(setup.player.loadedUrls, hasLength(1),
          reason: 'nor reopen the source the stop let go of');
      expect(setup.player.transport.last, 'stop');
      expect(setup.controller.state.status, PlaybackStatus.idle);
    });

    testWidgets(
        'a Play while a transient loss is still pending is never paused',
        (WidgetTester tester) async {
      final setup = await playing(tester);

      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await setup.controller.play();
      await tester.pump(_pastDebounce);

      expect(setup.player.pauseCalls, 0,
          reason: 'the debounce the Play superseded must not fire a pause');
      expect(setup.player.transport.last, 'play');
      expect(setup.controller.state.interruptedByTransientFocus, isFalse);
    });

    testWidgets('a Play in the same turn as a permanent loss ends playing',
        (WidgetTester tester) async {
      final setup = await playing(tester);

      // Another app takes audio, and the listener presses Play at once (the
      // permanent loss's pause is still queued).
      setup.controller
          .onAudioInterruption(_begin(AudioInterruptionType.unknown));
      await setup.controller.play();
      await tester.pump();

      expect(setup.player.pauseCalls, 0,
          reason: 'the queued focus pause must not undo the Play');
      expect(setup.player.transport.last, 'play');
      expect(setup.controller.state.playWhenReady, isTrue);
    });
  });

  // While a cast receiver owns the audio, the phone's focus is not ours to
  // recover, and ending the cast never surprise-starts local playback
  // (ActivePlaybackController resumes the engine paused).
  group('focus events while casting', () {
    testWidgets(
        'a call while casting arms nothing for the regain after the cast',
        (WidgetTester tester) async {
      final setup = await playing(tester);
      await setup.controller.suspend();

      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await tester.pump(_pastDebounce);
      expect(setup.controller.state.interruptedByTransientFocus, isFalse,
          reason: 'the receiver plays; nothing local is held');

      // The cast ends paused, then the call does.
      await setup.controller.resume();
      await tester.pump();
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await tester.pump();

      expect(setup.player.loadedUrls, hasLength(2),
          reason: 'the end of the cast reloads the track, paused');
      expect(setup.player.playCalls, 1,
          reason: 'the regain must not start the phone after a cast');
      expect(setup.controller.state.playWhenReady, isFalse);
    });

    testWidgets('a call held when the cast takes over is dropped with it',
        (WidgetTester tester) async {
      final setup = await pausedForACall(tester);

      await setup.controller.suspend();
      expect(setup.controller.state.interruptedByTransientFocus, isFalse,
          reason: 'the cast owns the audio; there is nothing to resume');

      await setup.controller.resume();
      await tester.pump();
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await tester.pump();

      expect(setup.player.playCalls, 1,
          reason: 'the regain must not start the phone after a cast');
      expect(setup.controller.state.playWhenReady, isFalse);
    });
  });

  group("a duck ends on the listener's own level", () {
    testWidgets('the unduck restores the chosen level, not full volume',
        (WidgetTester tester) async {
      final setup = await playing(tester);
      setup.controller.setVolume(0.5);
      await tester.pump();
      expect(setup.player.volumes.last, 0.5);

      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await tester.pump();
      expect(
        setup.player.volumes.last,
        closeTo(
          JustAudioPlaybackController.engineVolumeFor(
            _a,
            normalizeVolume: false,
            volume: 0.5,
            muted: false,
            ducked: true,
          ),
          1e-9,
        ),
        reason: 'the duck attenuates the chosen level',
      );

      setup.controller.onAudioInterruption(_end(AudioInterruptionType.duck));
      await tester.pump();

      expect(setup.player.volumes.last, 0.5);
      expect(setup.controller.state.volume, 0.5);
    });

    testWidgets('a regain that lifts a duck restores the chosen level too',
        (WidgetTester tester) async {
      final setup = await playing(tester);
      setup.controller.setVolume(0.5);
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await tester.pump();

      // The duck-end is never delivered; a bare focus gain lifts the duck.
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await tester.pump();

      expect(setup.controller.isDuckedForTesting, isFalse);
      expect(setup.player.volumes.last, 0.5);
    });

    testWidgets('the unduck never unmutes', (WidgetTester tester) async {
      final setup = await playing(tester);
      setup.controller.setVolume(0.5);
      setup.controller.setMuted(true);
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await tester.pump();

      setup.controller.onAudioInterruption(_end(AudioInterruptionType.duck));
      await tester.pump();

      expect(setup.player.volumes.last, 0.0);
      expect(setup.controller.state.muted, isTrue);
    });
  });
}
