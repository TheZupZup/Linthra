import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';

/// A fake engine that records the volume/play/pause traffic the controller's
/// audio-focus handling drives, with no platform channel. An injected player
/// turns off the controller's own audio_session wiring, so the test pumps focus
/// events straight into [JustAudioPlaybackController.onAudioInterruption].
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<double> volumes = <double>[];

  /// The ordered transport calls ('play' / 'pause') the controller drove, so a
  /// test can assert the *final* engine intent after a race (the last entry),
  /// not just how many of each happened.
  final List<String> transport = <String>[];
  int get playCalls => transport.where((t) => t == 'play').length;
  int get pauseCalls => transport.where((t) => t == 'pause').length;

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

  /// When true, `play()` returns a future that never completes — simulating
  /// just_audio, whose `play()` future only completes when playback *ends*. Lets
  /// a test prove the focus chain isn't blocked for the rest of the track.
  bool playNeverCompletes = false;
  final Completer<void> _blockedPlay = Completer<void>();

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> play() async {
    transport.add('play');
    if (playNeverCompletes) await _blockedPlay.future;
  }

  @override
  Future<void> pause() async => transport.add('pause');
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// Flushes the unawaited `setVolume`/`play`/`pause` continuations the handler
/// fires so the test can observe them.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// A short transient-loss debounce so a scheduled pause fires quickly in tests.
const Duration _testDebounce = Duration(milliseconds: 10);

/// Waits past [_testDebounce] so a scheduled transient-loss pause has fired.
Future<void> _pastDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

AudioInterruptionEvent _begin(AudioInterruptionType type) =>
    AudioInterruptionEvent(true, type);
AudioInterruptionEvent _end(AudioInterruptionType type) =>
    AudioInterruptionEvent(false, type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The field bug: with music playing, any other app grabbing a duckable
  // transient focus left Linthra silent and never recovering.
  // These exercise the controller's focus handling end to end via a
  // recording fake engine: a duck lowers (but never silences) the volume, and
  // any regain/unduck always restores it — so Linthra can never be left
  // muted/ducked once focus returns.
  group('audio focus duck/restore lifecycle', () {
    _RecordingPlayer player() => _RecordingPlayer();

    test('a duckable transient lowers the volume but keeps playing', () async {
      final p = player();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();

      expect(controller.isDuckedForTesting, isTrue);
      expect(p.volumes.last, lessThan(1.0),
          reason: 'a duckable transient attenuates the engine volume');
      expect(p.volumes.last, greaterThan(0.0),
          reason: 'ducking must stay audible, never silence');
      expect(p.pauseCalls, 0, reason: 'a duck keeps playing, never pauses');
    });

    test('the duck ending restores full volume', () async {
      final p = player();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.duck));
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0, reason: 'the unduck restores full volume');
    });

    test('a focus regain restores volume even after a duck (never stays muted)',
        () async {
      final p = player();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // Duck, then a bare GAIN arrives (the duck-end was never delivered): the
      // regain itself must still lift the duck.
      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0,
          reason: 'a regain must lift a lingering duck so we are never muted');
    });
  });

  group('audio focus pause/resume only on a transient loss', () {
    test('a sustained transient loss pauses, and the regain resumes', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // The loss outlasts the debounce window, so it really pauses.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      expect(p.pauseCalls, 1, reason: 'a sustained transient loss pauses');

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.playCalls, 1,
          reason: 'the matching regain resumes a focus-loss pause');
    });

    test('a brief transient loss blip is absorbed (never pauses)', () async {
      // The screen-off / Doze churn case: a transient loss immediately followed
      // by a regain must NOT pause — pausing would demote the foreground media
      // service and risk the OS freezing background playback with the screen off.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _pastDebounce();

      expect(p.pauseCalls, 0,
          reason: 'a loss cancelled by a quick regain must never pause');
      expect(p.playCalls, 0, reason: 'never paused, so nothing to resume');
    });

    test('a permanent loss pauses and a later regain does NOT resume',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.unknown));
      await _settle();
      expect(p.pauseCalls, 1, reason: 'a permanent loss pauses');

      controller.onAudioInterruption(_end(AudioInterruptionType.unknown));
      await _settle();
      expect(p.playCalls, 0,
          reason: 'a permanent loss must stay paused on return — no resume');
    });

    test('a bare regain with nothing armed does not start playback', () async {
      // The screen-wake / app-return case: focus comes back but no transient
      // loss armed a resume, so Linthra must not start playing by itself.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 0);
    });

    test('a transient loss while already paused does not resume on regain',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      // Engine is paused (not playing) when the loss arrives.
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 0,
          reason: 'only a loss that interrupted active playback resumes');
    });
  });

  group('voice session: repeated transient losses still resume on regain', () {
    // The remaining field bug: a single voice/mic session in another app emits
    // *several* transient losses back to back (may-duck focus on open, then
    // exclusive mic/voice focus — both surface as transient pauses with the
    // session set to pause-when-ducked). The 2nd loss must not disarm the resume
    // by observing the already-paused state, or the regain at the end never
    // restores sound.
    test('two sustained transient losses then one regain resume playback',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // First loss outlasts the debounce and pauses; simulate the engine going
      // paused.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      // Second loss arrives while already paused — must keep the resume armed.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();

      // Voice ends: a single regain must resume.
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 1,
          reason: 'a repeated transient loss must not disarm the resume');
    });

    test('a manual pause then a transient loss still does not resume',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      // The user paused first (engine paused, never armed by a focus loss).
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 0,
          reason: 'a user pause before the interruption must not auto-resume');
    });
  });

  group('foreground safety restore (volume only, never resumes)', () {
    test('foregrounding does NOT resume a focus-loss pause (gain owns resume)',
        () async {
      // Resuming on a mere foreground event could restart audio over an
      // interruption that still holds focus (e.g. opening Linthra mid-call).
      // Resume is left entirely to the real AUDIOFOCUS_GAIN, which is now
      // processed reliably in the background.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAppForegrounded();
      await _settle();
      expect(p.playCalls, 0,
          reason: 'foreground must not resume while focus may still be held');

      // The real regain still resumes.
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.playCalls, 1, reason: 'the AUDIOFOCUS_GAIN owns the resume');
    });

    test('foregrounding restores a lingering duck even with no gain', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      await _settle();
      expect(controller.isDuckedForTesting, isTrue);

      controller.onAppForegrounded();
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0,
          reason: 'a foreground return must lift a lingering duck');
    });

    test('foregrounding does not resume a user pause', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      // Plain user pause: no focus loss ever armed a resume.
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAppForegrounded();
      await _settle();

      expect(p.playCalls, 0,
          reason: 'foregrounding must never resume a track the user paused');
    });

    test('foregrounding while playing normally changes nothing', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAppForegrounded();
      await _settle();

      expect(p.playCalls, 0);
      expect(p.volumes, isEmpty);
    });
  });

  // The intermittent (~1-in-2) field failure was a race: transport was issued
  // fire-and-forget from several triggers (the debounce timer, the interruption
  // stream, the foreground callback), so a pause and its resume could overlap
  // and settle nondeterministically. Transport now runs through one serialized
  // chain and the latest focus decision wins (stale actions are skipped), so the
  // *final* engine intent is deterministic regardless of event ordering/timing.
  group('focus recovery is deterministic under racing/stale events', () {
    test('pause then an immediate regain ends playing (last intent wins)',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = Duration.zero;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // Loss → the (zero-debounce) pause is enqueued, then a regain arrives.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _settle();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.transport, isNotEmpty);
      expect(p.transport.last, 'play',
          reason: 'whatever the interleaving, recovery must end playing');
    });

    test('a regain superseding a queued pause never leaves us paused',
        () async {
      // Drive the boundary where the debounce pause has been enqueued onto the
      // chain but a regain supersedes it: the engine must end playing, not stuck
      // paused.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce(); // pause applied
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.transport.last, 'play');
    });

    test('a manual pause during a pending loss blocks the later regain resume',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // Transient loss arms a resume (debounce still pending)…
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      // …but the user pauses explicitly before it resolves.
      await controller.pause();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      await _pastDebounce();

      // Focus returns: a user pause must veto the auto-resume.
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 0,
          reason: 'an explicit user pause must never auto-resume on regain');
    });

    test('foreground restore racing a focus gain ends playing, not paused',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce(); // paused for focus
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      // Unlock both foregrounds the app (volume-only safety net) and delivers
      // the gain that owns the resume — the result must converge on playing.
      controller.onAppForegrounded();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.transport.last, 'play',
          reason: 'the focus gain must resume; foreground must not fight it');
    });

    test('a later focus loss still pauses after a recovered resume', () async {
      // just_audio's play() future only completes when the track ends, so the
      // resume's play() must NOT be awaited on the serialized chain — otherwise
      // a new interruption (a call after a recovered prompt) would be queued
      // behind the still-running play and never pause until the song finished.
      final p = _RecordingPlayer()..playNeverCompletes = true;
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // First interruption, then recover → resume (play that "never completes").
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.transport.contains('play'), isTrue,
          reason: 'the regain resumes');
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      // A new interruption during the same still-playing track must pause.
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();

      expect(p.transport.last, 'pause',
          reason: 'a later focus loss must pause even though the resume play() '
              'future has not completed — the chain must not block on it');
    });

    test('volume restore is idempotent across repeated recoveries', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      // Several recovery signals in a row must all be safe and converge on full.
      controller.onAudioInterruption(_end(AudioInterruptionType.duck));
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      controller.onAppForegrounded();
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0,
          reason: 'repeated restores must leave full volume, never ducked');
    });

    test('a stale duck event cannot leave the player ducked after a regain',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.duck));
      controller
          .onAudioInterruption(_end(AudioInterruptionType.pause)); // regain
      await _settle();

      expect(controller.isDuckedForTesting, isFalse);
      expect(p.volumes.last, 1.0);
    });
  });

  // #499 — battery-optimal audio-focus mode. The foreground media service (and
  // the CPU wake lock audio_service holds with it) is kept alive *only* while a
  // transient-focus pause is outstanding, instead of across every pause as #244
  // left it. The controller publishes that as
  // `PlaybackState.interruptedByTransientFocus`, which the media session turns
  // into the `playing` flag audio_service promotes the service on.
  group('the foreground hold covers a transient-focus pause only (#499)', () {
    test('a sustained transient loss holds it, and the regain releases it',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      expect(controller.state.interruptedByTransientFocus, isFalse,
          reason: 'normal playback needs no hold — it is already foreground');

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();

      expect(controller.state.interruptedByTransientFocus, isTrue,
          reason: 'the isolate must stay alive to see the AUDIOFOCUS_GAIN');
      expect(p.pauseCalls, 1);

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(p.playCalls, 1, reason: 'the regain still resumes playback');
      // The engine sounds again; from then on playing keeps the service up.
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      expect(controller.state.interruptedByTransientFocus, isFalse,
          reason: 'focus is back: playing keeps the service up on its own');
    });

    // Android 17 refuses audio focus to a backgrounded app with no foreground
    // service, and silences its audio. The regain's resume asks for focus, so
    // the session must not report paused (which takes the media service out of
    // the foreground) between the regain and the engine sounding again.
    test('the regain keeps the service held until the engine plays again',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      expect(controller.state.status, PlaybackStatus.paused);
      expect(controller.state.interruptedByTransientFocus, isTrue);

      final List<PlaybackState> seen = <PlaybackState>[];
      final StreamSubscription<PlaybackState> sub =
          controller.stateStream.listen(seen.add);
      addTearDown(sub.cancel);

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.playCalls, 1);
      expect(controller.state.interruptedByTransientFocus, isTrue,
          reason: 'the engine has not sounded yet, so the hold must stand');

      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      await _settle();

      expect(
        seen.where((PlaybackState s) =>
            s.status == PlaybackStatus.paused &&
            !s.interruptedByTransientFocus),
        isEmpty,
        reason: 'a paused, unheld state demotes the media service right as '
            'the resume asks for audio focus',
      );
      expect(controller.state.status, PlaybackStatus.playing);
      expect(controller.state.interruptedByTransientFocus, isFalse,
          reason: 'once playing, nothing is left for the hold to bridge');
    });

    test('a pause after the regain drops a hold still waiting on the engine',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(controller.state.interruptedByTransientFocus, isTrue);

      // The user gives up on it and pauses: nothing is left to bridge.
      await controller.pause();
      await _settle();
      expect(controller.state.interruptedByTransientFocus, isFalse);
    });

    test('the hold reaches listeners on the state stream', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      final held = <bool>[];
      final sub = controller.stateStream
          .listen((s) => held.add(s.interruptedByTransientFocus));
      addTearDown(sub.cancel);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      await _settle();

      expect(held, contains(true),
          reason: 'the media session is driven by the stream, not by polling');
      expect(held.last, isFalse);
    });

    test('a brief blip absorbed by the regain leaves no hold behind', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _pastDebounce();

      expect(p.pauseCalls, 0);
      expect(controller.state.interruptedByTransientFocus, isFalse);
    });

    test('a permanent loss never holds it (another app owns audio now)',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.unknown));
      await _settle();

      expect(controller.state.interruptedByTransientFocus, isFalse,
          reason: 'nothing to recover, so nothing to keep the service up for');
    });

    test('a transient loss over an already-paused track never holds it',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();

      expect(controller.state.interruptedByTransientFocus, isFalse,
          reason: 'a user-paused track has no playback to protect');
    });

    test('a user pause during a transient hold demotes the service', () async {
      // The battery case the #244 configuration could not express: the user
      // pauses while another app still holds focus, so there is no longer
      // anything to resume — the wake lock must be dropped straight away.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      expect(controller.state.interruptedByTransientFocus, isTrue);

      await controller.pause();
      await _settle();

      expect(controller.state.interruptedByTransientFocus, isFalse);

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.playCalls, 0,
          reason: 'a user pause still wins over the later regain');
    });

    test('a stop releases the hold', () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      expect(controller.state.interruptedByTransientFocus, isTrue);

      await controller.stop();

      expect(controller.state.interruptedByTransientFocus, isFalse);
    });

    test('the hold is bounded when the focus gain never arrives', () async {
      // An app that grabbed focus and died never sends AUDIOFOCUS_GAIN. Without
      // a bound that would hold the wake lock for as long as the track stays
      // paused — the very cost #499 is about.
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.focusHoldTimeout = const Duration(milliseconds: 60);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      expect(controller.state.interruptedByTransientFocus, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(controller.state.interruptedByTransientFocus, isFalse,
          reason: 'the hold must expire on its own, not linger indefinitely');

      // The resume goes with the hold. With the media service out of the
      // foreground, a resume on a late regain would start audio from the
      // background, which Android 17 silences (and earlier versions can refuse
      // the service's return to the foreground for). The listener presses
      // Play instead.
      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(p.playCalls, 0);
      expect(controller.state.playWhenReady, isFalse,
          reason: 'nothing loading or retrying may start sound on its own '
              'once the hold is gone');
    });

    test('a repeated voice-session loss keeps the hold through to the regain',
        () async {
      final p = _RecordingPlayer();
      final controller = JustAudioPlaybackController(player: p);
      addTearDown(controller.dispose);
      controller.focusPauseDebounce = _testDebounce;
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();
      controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await _pastDebounce();

      expect(controller.state.interruptedByTransientFocus, isTrue,
          reason:
              'the second loss of one voice session must not drop the hold');

      controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      expect(p.playCalls, 1);
      expect(controller.state.interruptedByTransientFocus, isFalse);
    });
  });
}
