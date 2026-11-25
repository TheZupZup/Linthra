// #905: a server that stops answering mid-track on Linux.
//
// libmpv retries such a stream on its own for about half a minute, then gives
// up by reporting the end of the file, and just_audio passes that on as
// `completed`. Taken at its word, the track counted as played and the queue
// moved on to a next track that ran into the same dead server. A stream that
// "ends" well short of its known length was lost: it is recovered like any
// dropped stream, at its position. A local file, or a stream that ends
// within the tolerance an estimated VBR length needs, still ends.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

const Duration _length = Duration(seconds: 40);

/// The Linux engine as just_audio_media_kit drives it.
class _Engine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> states =
      StreamController<PlayerState>.broadcast(sync: true);
  final StreamController<Duration?> durations =
      StreamController<Duration?>.broadcast(sync: true);
  final List<String> opened = <String>[];

  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      const Stream<PlaybackEvent>.empty();

  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    opened.add(url);
    return _length;
  }

  @override
  Future<void> play() async =>
      states.add(PlayerState(true, ProcessingState.ready));
  @override
  Future<void> pause() async =>
      states.add(PlayerState(false, ProcessingState.ready));
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {}

  /// What libmpv reports for a server that stopped answering: buffering
  /// while it retries, then the end of the file.
  void giveUpAsEndOfFile() {
    states.add(PlayerState(true, ProcessingState.buffering));
    states.add(PlayerState(true, ProcessingState.completed));
  }

  Future<void> close() async {
    await states.close();
    await durations.close();
  }
}

class _Resolver implements PlayableUriResolver {
  _Resolver(this.source);

  final PlaybackSource source;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async =>
      ResolvedPlayable(Uri.parse('https://music.example/${track.id}'), source);
}

void main() {
  const Track a = Track(id: 'a', title: 'a', uri: 'jellyfin:a');
  const Track b = Track(id: 'b', title: 'b', uri: 'jellyfin:b');

  /// A controller playing [a] (40 s) with [b] next, heard up to [position],
  /// recording every track it counts as played to its end.
  Future<({LinuxPlaybackController controller, List<Track> completed})>
      heardUpTo(
          _Engine engine, PlaybackSource source, Duration position) async {
    final List<Track> completed = <Track>[];
    final LinuxPlaybackController controller = LinuxPlaybackController(
      player: engine,
      resolver: _Resolver(source),
      onTrackCompleted: completed.add,
    )..streamRetryBackoff = Duration.zero;
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    await controller.playTracks(<Track>[a, b]);
    engine.durations.add(_length);
    controller.setPositionForTesting(position);
    expect(controller.state.status, PlaybackStatus.playing);
    return (controller: controller, completed: completed);
  }

  test('a stream libmpv gives up on is reconnected, not counted as played',
      () async {
    final _Engine engine = _Engine();
    // Measured: libmpv gave up at 11.9 s of a 40 s stream.
    final setup = await heardUpTo(engine, PlaybackSource.streamingDirect,
        const Duration(milliseconds: 11900));

    engine.giveUpAsEndOfFile();
    await pumpEventQueue();

    expect(setup.completed, isEmpty, reason: 'it was not heard to its end');
    expect(setup.controller.state.currentTrack?.id, 'a',
        reason: 'the queue must not move on to a track on the same server');
    expect(engine.opened, hasLength(2),
        reason: 'the stream is opened again to reconnect');
  });

  test('a stream that ends within the tolerance still ends', () async {
    final _Engine engine = _Engine();
    // An estimated VBR length a few seconds out.
    final setup = await heardUpTo(
        engine, PlaybackSource.streamingDirect, const Duration(seconds: 33));

    engine.giveUpAsEndOfFile();
    await pumpEventQueue();

    expect(setup.completed.map((Track t) => t.id), <String>['a']);
    expect(setup.controller.state.currentTrack?.id, 'b');
  });

  test('a local file that reports its end, ends', () async {
    final _Engine engine = _Engine();
    final setup = await heardUpTo(
        engine, PlaybackSource.localFile, const Duration(milliseconds: 11900));

    engine.giveUpAsEndOfFile();
    await pumpEventQueue();

    expect(setup.completed.map((Track t) => t.id), <String>['a']);
    expect(setup.controller.state.currentTrack?.id, 'b');
  });
}
