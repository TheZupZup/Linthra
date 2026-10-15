// "Reconnecting…" holds for the whole bounded reconnect.
//
// After a stream drops, the controller shows reconnecting and waits out a
// short backoff before reloading. The engine still holds the dead source
// meanwhile, and goes on reporting buffering or loading from it (ExoPlayer
// retrying the connection; a pause during the wait reads as loading). Let
// through, those reports would turn the UI and the media session back to a
// plain "Buffering…" or "Loading…", as if the stream were merely slow, while
// the reconnect is still under way.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/stream_interruption.dart';

/// An engine that reports nothing on its own: the test feeds every state
/// through [JustAudioPlaybackController.handleEngineState].
class _Player extends Fake implements AudioPlayer {
  final List<String> setUrlCalls = <String>[];

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
    setUrlCalls.add(url);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

class _Resolver implements PlayableUriResolver {
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.id}?n=${calls.length}'),
      PlaybackSource.streamingDirect,
    );
  }
}

const Track _song = Track(id: 'j', title: 'Song', uri: 'jellyfin:j');

const StreamInterruption _networkDrop = StreamInterruption(
  StreamInterruptionKind.networkDropped,
  'The connection dropped while streaming. Check your connection and try '
  'again.',
  retryable: true,
);

void main() {
  testWidgets(
      'buffering and loading from the dead source during the backoff keep '
      'it reconnecting', (WidgetTester tester) async {
    final _Player player = _Player();
    final _Resolver resolver = _Resolver();
    final JustAudioPlaybackController controller =
        JustAudioPlaybackController(player: player, resolver: resolver)
          ..streamRetryBackoff = const Duration(seconds: 2)
          ..midStreamBufferingTimeout = const Duration(hours: 1);
    await controller.playTracks(<Track>[_song]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));

    unawaited(controller.handleStreamFailureForTestingAsync(_networkDrop));
    await tester.pump();
    expect(controller.state.status, PlaybackStatus.reconnecting);
    expect(resolver.calls, hasLength(1), reason: 'still in the backoff');

    // The engine keeps trying the dead connection, and reports it, all
    // through the backoff.
    controller.handleEngineState(PlayerState(true, ProcessingState.buffering));
    expect(controller.state.status, PlaybackStatus.reconnecting);
    await tester.pump(const Duration(seconds: 1));
    controller.handleEngineState(PlayerState(true, ProcessingState.loading));
    expect(controller.state.status, PlaybackStatus.reconnecting);
    controller.handleEngineState(PlayerState(false, ProcessingState.buffering));
    expect(controller.state.status, PlaybackStatus.reconnecting);
    expect(resolver.calls, hasLength(1), reason: 'still in the backoff');

    // The reconnect still runs once the backoff is over.
    await tester.pump(const Duration(seconds: 2));
    expect(resolver.calls, hasLength(2));
    expect(player.setUrlCalls, hasLength(2));
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    expect(controller.state.status, PlaybackStatus.playing);

    // Disposed inside the test so none of its timers outlives it.
    unawaited(controller.dispose());
    await tester.pump();
  });
}
