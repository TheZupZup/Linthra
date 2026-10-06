import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/services/remote_control_receiver.dart';
import 'package:linthra/core/services/remote_control_service.dart';

import '../../features/player/fake_playback_controller.dart';

/// An engine that records every source it is handed and counts the plays it
/// is told, so a test can see which songs were really loaded and started.
class _RecordingEngine extends Fake implements AudioPlayer {
  final List<String> loaded = <String>[];
  int plays = 0;

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
    loaded.add(url);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

/// A server that answers each stream request on the next turn of the event
/// loop: a network round trip, as short as one can be.
class _ServerResolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    await Future<void>.delayed(Duration.zero);
    return ResolvedPlayable(
      Uri.parse('https://host/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

/// just_audio's shape where the order of commands matters: play() and pause()
/// flip the playing flag at once, stop() lets go of the source after a
/// platform round trip (held here until the test lets it finish), and play()
/// after a stop opens the source it kept again.
class _StoppableEngine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  /// While set, stop() waits for it before letting go of the source.
  Completer<void>? stopHeld;

  bool _playing = false;
  bool _opened = false;
  String? source;

  /// Whether the speakers are playing [source].
  bool get audible => _playing && _opened;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
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
    source = url;
    _opened = false;
    _states.add(PlayerState(_playing, ProcessingState.loading));
    await Future<void>.delayed(Duration.zero);
    _opened = true;
    _durations.add(const Duration(minutes: 3));
    _states.add(PlayerState(_playing, ProcessingState.ready));
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    _playing = true;
    if (!_opened && source != null) {
      _states.add(PlayerState(true, ProcessingState.loading));
      await Future<void>.delayed(Duration.zero);
      _opened = true;
    }
    _states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _states.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> stop() async {
    _playing = false;
    final Completer<void>? held = stopHeld;
    if (held != null) await held.future;
    _opened = false;
    _states.add(PlayerState(false, ProcessingState.idle));
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {}
}

/// A [RemoteControlReceiver] driven directly by a test [StreamController], so a
/// test can push neutral commands without any real transport.
class _StreamReceiver implements RemoteControlReceiver {
  _StreamReceiver(this._commands);

  final StreamController<RemoteCommand> _commands;

  @override
  Stream<RemoteCommand> get commands => _commands.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late StreamController<RemoteCommand> commands;
  late FakePlaybackController controller;
  late RemoteControlService service;

  setUp(() {
    commands = StreamController<RemoteCommand>.broadcast();
    controller = FakePlaybackController();
    service = RemoteControlService(
      receiver: _StreamReceiver(commands),
      controller: controller,
    );
  });

  tearDown(() async {
    await service.dispose();
    await controller.dispose();
    await commands.close();
  });

  Future<void> send(RemoteCommand command) async {
    commands.add(command);
    await pumpEventQueue();
  }

  test('play command starts the controller', () async {
    await send(const RemotePlay());
    expect(controller.playCount, 1);
    expect(controller.pauseCount, 0);
  });

  test('pause command pauses the controller', () async {
    await send(const RemotePause());
    expect(controller.pauseCount, 1);
  });

  test('stop command stops the controller', () async {
    await send(const RemoteStop());
    expect(controller.stopCount, 1);
  });

  test('next command skips to the next track', () async {
    await send(const RemoteNext());
    expect(controller.skipCount, 1);
  });

  test('previous command steps to the previous track', () async {
    await send(const RemotePrevious());
    expect(controller.previousCount, 1);
  });

  test('seek command seeks to the requested position', () async {
    await send(const RemoteSeek(Duration(seconds: 42)));
    expect(controller.seeks, <Duration>[const Duration(seconds: 42)]);
  });

  test('play/pause toggles to pause while playing', () async {
    controller.emit(
      PlaybackState.idle.copyWith(status: PlaybackStatus.playing),
    );
    await send(const RemotePlayPause());
    expect(controller.pauseCount, 1);
    expect(controller.playCount, 0);
  });

  test('play/pause toggles to play while not playing', () async {
    // The default fake state is idle (not playing).
    await send(const RemotePlayPause());
    expect(controller.playCount, 1);
    expect(controller.pauseCount, 0);
  });

  test('play/pause pauses a stream that is re-buffering or reconnecting',
      () async {
    // A stall mid-stream is still playback: the sound comes back on its own
    // once data arrives, and the server still shows the track playing, so a
    // toggle pressed then means pause (as the app's button and MPRIS read it).
    for (final PlaybackStatus stalled in <PlaybackStatus>[
      PlaybackStatus.buffering,
      PlaybackStatus.reconnecting,
    ]) {
      controller.emit(PlaybackState.idle.copyWith(status: stalled));
      await send(const RemotePlayPause());
    }
    expect(controller.pauseCount, 2);
    expect(controller.playCount, 0);
  });

  test('play/pause plays a stall the listener already paused', () async {
    for (final PlaybackStatus stalled in <PlaybackStatus>[
      PlaybackStatus.buffering,
      PlaybackStatus.reconnecting,
    ]) {
      controller.emit(
        PlaybackState.idle.copyWith(status: stalled, playWhenReady: false),
      );
      await send(const RemotePlayPause());
    }
    expect(controller.playCount, 2);
    expect(controller.pauseCount, 0);
  });

  test('a burst of commands all apply', () async {
    commands.add(const RemotePlay());
    commands.add(const RemoteSeek(Duration(seconds: 5)));
    commands.add(const RemotePause());
    await pumpEventQueue();
    expect(controller.playCount, 1);
    expect(controller.seeks, <Duration>[const Duration(seconds: 5)]);
    expect(controller.pauseCount, 1);
  });

  // A remote's presses reach the player the way on-screen taps do: taken at
  // once, without waiting for the track the last one started loading.
  group('with the real player, from a server that takes a moment', () {
    late _RecordingEngine engine;
    late JustAudioPlaybackController player;
    late StreamController<RemoteCommand> remote;

    setUp(() async {
      engine = _RecordingEngine();
      player = JustAudioPlaybackController(
        player: engine,
        resolver: _ServerResolver(),
      );
      remote = StreamController<RemoteCommand>.broadcast();
      final RemoteControlService bridge = RemoteControlService(
        receiver: _StreamReceiver(remote),
        controller: player,
      );
      addTearDown(remote.close);
      addTearDown(player.dispose);
      addTearDown(bridge.dispose);
      await player.playTracks(<Track>[
        for (final String id in <String>['1', '2', '3', '4'])
          Track(id: id, title: id, uri: 'jellyfin:$id'),
      ]);
      expect(engine.loaded, <String>['https://host/1']);
      expect(engine.plays, 1);
    });

    test('three quick Nexts play only the song they land on', () async {
      remote
        ..add(const RemoteNext())
        ..add(const RemoteNext())
        ..add(const RemoteNext());
      await pumpEventQueue();

      expect(player.state.currentTrack?.id, '4');
      expect(engine.loaded, <String>['https://host/1', 'https://host/4'],
          reason: 'songs 2 and 3 were loaded and started on the way');
      expect(engine.plays, 2);
    });

    test('a Pause right after a Next keeps the next song from starting',
        () async {
      remote
        ..add(const RemoteNext())
        ..add(const RemotePause());
      await pumpEventQueue();

      expect(player.state.currentTrack?.id, '2');
      expect(engine.loaded.last, 'https://host/2');
      expect(engine.plays, 1,
          reason: 'the next song started before the Pause was applied');
    });
  });

  group('with the real player, when the engine takes a moment to stop', () {
    // A Stop sent together with the command after it, as an automation does
    // ("restart": Stop then Play) or someone quick on the remote. The stop
    // settles the player as stopped once the engine has let go of its
    // source; what came after it must not be undone by that.
    late _StoppableEngine engine;
    late JustAudioPlaybackController player;
    late StreamController<RemoteCommand> remote;

    setUp(() async {
      engine = _StoppableEngine();
      player = JustAudioPlaybackController(
        player: engine,
        resolver: _ServerResolver(),
      );
      remote = StreamController<RemoteCommand>.broadcast();
      final RemoteControlService bridge = RemoteControlService(
        receiver: _StreamReceiver(remote),
        controller: player,
      );
      addTearDown(remote.close);
      addTearDown(player.dispose);
      addTearDown(bridge.dispose);
      await player.playTracks(<Track>[
        for (final String id in <String>['1', '2'])
          Track(id: id, title: id, uri: 'jellyfin:$id'),
      ]);
      await pumpEventQueue();
      expect(player.state.status, PlaybackStatus.playing);
      expect(engine.audible, isTrue);
    });

    test('a Play right after a Stop starts the song again', () async {
      final Completer<void> stopping = engine.stopHeld = Completer<void>();
      remote
        ..add(const RemoteStop())
        ..add(const RemotePlay());
      await pumpEventQueue();
      stopping.complete();
      await pumpEventQueue();

      expect(player.state.status, PlaybackStatus.playing,
          reason: 'the stop, finishing after the Play, undid it');
      expect(engine.audible, isTrue);
      expect(engine.source, 'https://host/1');
    });

    test('a Next right after a Stop plays the next song', () async {
      final Completer<void> stopping = engine.stopHeld = Completer<void>();
      remote
        ..add(const RemoteStop())
        ..add(const RemoteNext());
      await pumpEventQueue();
      stopping.complete();
      await pumpEventQueue();

      expect(player.state.currentTrack?.id, '2');
      expect(player.state.status, PlaybackStatus.playing,
          reason: 'the stop, finishing after the Next, undid it');
      expect(engine.audible, isTrue);
      expect(engine.source, 'https://host/2');
    });
  });

  test('no command is applied after dispose', () async {
    await service.dispose();
    commands.add(const RemotePlay());
    await pumpEventQueue();
    expect(controller.playCount, 0);
  });

  test('a no-op receiver drives nothing', () async {
    final RemoteControlService idle = RemoteControlService(
      receiver: const NoOpRemoteControlReceiver(),
      controller: controller,
    );
    await pumpEventQueue();
    expect(controller.playCount, 0);
    expect(controller.pauseCount, 0);
    await idle.dispose();
  });
}
