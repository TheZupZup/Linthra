// The foreground hold of a transient focus loss running out while an
// automatic recovery step is waiting.
//
// A call holds playback, and the listener skips (from a headset or the
// notification) to a track whose server doesn't answer: the failure waits on
// an automatic retry, which would start sound only after the regain. If the
// regain never comes, the hold is bounded by focusHoldTimeout, and when it
// runs out nothing may start sound on its own any more: the media service has
// left the foreground, so a retry landing later would start audio from the
// background, which Android 17 silences. The waiting step must go with the
// hold, settling on the failure, and a regain after that must not resume.
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';

/// Records the engine's transport calls in order; reports nothing itself.
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<String> transport = <String>[];

  int get playCalls => transport.where((String t) => t == 'play').length;

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
  }) async =>
      const Duration(minutes: 3);

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => transport.add('play');
  @override
  Future<void> pause() async => transport.add('pause');
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

/// Resolves every track, except those in [down], whose server can't be
/// reached. Records every resolve.
class _Resolver implements PlayableUriResolver {
  final Set<String> down = <String>{};
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    if (down.contains(track.uri)) {
      throw const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    return ResolvedPlayable(
      Uri.parse('https://host/stream/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

const Track _a = Track(id: 'a', title: 'A', uri: 'jellyfin:a');
const Track _b = Track(id: 'b', title: 'B', uri: 'jellyfin:b');

void main() {
  testWidgets(
      'a recovery step waiting when the hold runs out never runs, and the '
      'late regain stays silent', (WidgetTester tester) async {
    final _RecordingPlayer player = _RecordingPlayer();
    final _Resolver resolver = _Resolver()..down.add(_b.uri);
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      // The automatic retry waits far longer than the hold lasts.
      automaticRecovery:
          const PlaybackRecoveryPolicy(retryDelay: Duration(minutes: 5)),
    )
      ..focusPauseDebounce = const Duration(milliseconds: 10)
      ..focusHoldTimeout = const Duration(milliseconds: 50);
    await controller.playTracks(<Track>[_a, _b]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));

    // A call comes in and outlasts the debounce.
    controller.onAudioInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await tester.pump(const Duration(milliseconds: 20));
    controller.handleEngineState(PlayerState(false, ProcessingState.ready));
    expect(controller.state.interruptedByTransientFocus, isTrue);

    // Next from a headset during the call: B's server doesn't answer, and
    // its failure waits on the automatic retry.
    await controller.skipToNext();
    await tester.pump();
    expect(controller.state.currentTrack, _b);
    expect(controller.hasPendingAutomaticRecovery, isTrue);
    final int resolves = resolver.calls.length;
    final int plays = player.playCalls;

    // The regain never comes before the hold runs out.
    await tester.pump(const Duration(milliseconds: 50));

    expect(controller.state.interruptedByTransientFocus, isFalse);
    expect(controller.hasPendingAutomaticRecovery, isFalse,
        reason: 'the waiting step must go with the hold');
    expect(controller.state.status, PlaybackStatus.error,
        reason: 'it settles on the failure it was waiting out');
    expect(controller.state.currentTrack, _b);
    expect(controller.state.playWhenReady, isFalse);

    // Well past when the retry would have run.
    await tester.pump(const Duration(minutes: 10));
    expect(resolver.calls, hasLength(resolves),
        reason: 'no retry may start sound from the background');

    // The call finally ends.
    controller.onAudioInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await tester.pump();

    expect(player.playCalls, plays,
        reason: 'the resume went with the hold; the listener presses Play');
    expect(resolver.calls, hasLength(resolves));
    expect(controller.state.status, PlaybackStatus.error);

    // Disposed inside the test so none of its timers outlives it.
    unawaited(controller.dispose());
    await tester.pump();
  });
}
