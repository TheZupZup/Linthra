import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/mpris/mpris_player_object.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// An engine that reports its state the way just_audio does: ready once a
/// source is open, with its playing flag following play and pause.
class _Engine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();
  bool _playing = false;
  int playCalls = 0;

  /// The connection under the stream dies.
  void dropStream() => _events.addError(Exception('Connection reset'));

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    _states.add(PlayerState(_playing, ProcessingState.ready));
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing = true;
    _states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _states.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
    await _events.close();
  }
}

/// A server that answers at once until told to hold its next answer.
class _SlowServer implements PlayableUriResolver {
  Completer<void>? hold;
  int _n = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final Completer<void>? gate = hold;
    if (gate != null) await gate.future;
    _n++;
    return ResolvedPlayable(
      Uri.parse('https://music.example/stream/${track.id}?n=$_n'),
      PlaybackSource.streamingDirect,
    );
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('the media key resumes a reconnect the listener paused (#806)',
      () async {
    final _Engine engine = _Engine();
    final _SlowServer server = _SlowServer();
    final LinuxPlaybackController controller =
        LinuxPlaybackController(player: engine, resolver: server)
          ..streamRetryBackoff = Duration.zero
          ..midStreamBufferingTimeout = const Duration(hours: 1);
    addTearDown(controller.dispose);
    final MprisPlayerObject mpris = MprisPlayerObject(controller);
    Future<void> press(String method) => mpris.handleMethodCall(
          DBusMethodCall(
            sender: ':1.7',
            interface: MprisPlayerObject.playerInterface,
            name: method,
          ),
        );
    DBusValue? status() =>
        mpris.properties(MprisPlayerObject.playerInterface)['PlaybackStatus'];

    const Track song = Track(id: 's', title: 'Song', uri: 'jellyfin:s');
    await controller.playTracks(<Track>[song]);
    await _settle();
    expect(controller.state.status, PlaybackStatus.playing);

    // The stream drops and the server is slow to answer the reconnect.
    server.hold = Completer<void>();
    engine.dropStream();
    await _settle();
    expect(controller.state.status, PlaybackStatus.reconnecting);

    await press('PlayPause');
    await _settle();
    expect(status(), const DBusString('Paused'),
        reason: 'the shell shows what the listener did');

    // The listener changes their mind before the server answers.
    await press('PlayPause');
    await _settle();
    expect(controller.state.playWhenReady, isTrue);
    expect(status(), const DBusString('Playing'));

    final int playsBefore = engine.playCalls;
    server.hold!.complete();
    await _settle();

    expect(engine.playCalls, playsBefore + 1,
        reason: 'the reconnect starts sound when it lands');
    expect(controller.state.status, PlaybackStatus.playing);
  });
}
