// The end of a song on Linux, when libmpv reports it as buffering first.
//
// libmpv goes idle at the end of a file, and media_kit passes that on as a
// moment of buffering before anything else. For a song whose last bytes don't
// decode (a Lyrics3 tag, padding, a cut-off last frame) the vendored
// just_audio_media_kit then reports the lost source as an idle engine, about
// half a second before the end libmpv announced. Heard right up to there, the
// song ended, and the queue moves on: the buffering report on the way must not
// turn that end into a failure. A source lost well before its end is still
// one, however short the song: "near the end" is capped at a quarter of it.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// The Linux engine as just_audio_media_kit drives it: it reports playing as
/// soon as it is asked to, and a lost source only as an idle state.
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
    return const Duration(milliseconds: 4048);
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

  /// libmpv reaching the end of the file: a moment of buffering.
  void bufferAtTheEnd() =>
      states.add(PlayerState(true, ProcessingState.buffering));

  /// The source lost, reported only as an idle engine (no error event).
  void loseSourceAsLinuxDoes() =>
      states.add(PlayerState(true, ProcessingState.idle));

  Future<void> close() async {
    await states.close();
    await durations.close();
  }
}

class _Resolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async =>
      ResolvedPlayable(Uri.file(track.uri), PlaybackSource.localFile);
}

void main() {
  late Directory dir;
  late Track a;
  late Track b;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('linthra-eof');
    a = Track(id: 'a', title: 'a', uri: '${dir.path}/a.mp3');
    b = Track(id: 'b', title: 'b', uri: '${dir.path}/b.mp3');
    File(a.uri).writeAsBytesSync(<int>[1, 2, 3]);
    File(b.uri).writeAsBytesSync(<int>[1, 2, 3]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A controller playing a 4.048 s [a] with [b] next, heard up to
  /// [position], recording every track it counts as played to its end.
  Future<({LinuxPlaybackController controller, List<Track> completed})>
      heardUpTo(_Engine engine, Duration position) async {
    final List<Track> completed = <Track>[];
    final LinuxPlaybackController controller = LinuxPlaybackController(
      player: engine,
      resolver: _Resolver(),
      onTrackCompleted: completed.add,
    );
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    await controller.playTracks(<Track>[a, b]);
    engine.durations.add(const Duration(milliseconds: 4048));
    controller.setPositionForTesting(position);
    expect(controller.state.status, PlaybackStatus.playing);
    return (controller: controller, completed: completed);
  }

  test('a source lost just after the end-of-file buffering is the song ending',
      () async {
    final _Engine engine = _Engine();
    // libmpv 2.2, natively: a 4.05 s MP3 went idle at 3.42 s.
    final setup = await heardUpTo(engine, const Duration(milliseconds: 3419));

    engine.bufferAtTheEnd();
    expect(setup.controller.state.status, PlaybackStatus.buffering);
    engine.loseSourceAsLinuxDoes();
    await pumpEventQueue();

    expect(setup.controller.state.failure, isNull,
        reason: 'the whole song played: there is nothing to report');
    expect(setup.completed.map((Track t) => t.id), <String>['a']);
    expect(setup.controller.state.currentTrack?.id, 'b');
    expect(setup.controller.state.status, PlaybackStatus.playing);
  });

  test(
      'a source lost within two seconds of the end of a short song, but '
      'before its last quarter, is still a failure', () async {
    final _Engine engine = _Engine();
    // 1.548 s before the end: inside the two-second margin, but more than a
    // quarter of a 4.048 s song.
    final setup = await heardUpTo(engine, const Duration(milliseconds: 2500));

    engine.bufferAtTheEnd();
    engine.loseSourceAsLinuxDoes();
    await pumpEventQueue();

    expect(setup.controller.state.status, PlaybackStatus.error);
    expect(setup.controller.state.currentTrack?.id, 'a');
    expect(setup.completed, isEmpty);
    expect(engine.opened, hasLength(1), reason: 'nothing moved on to b');
  });
}
