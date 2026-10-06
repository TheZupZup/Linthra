import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';

import '../../support/fake_machine_sleep.dart';

/// Controllable engine for the reload after a system sleep, with no platform
/// channel.
class _Engine extends Fake implements AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  final List<String> setUrlCalls = <String>[];
  final List<Duration?> seekCalls = <Duration?>[];
  int playCalls = 0;
  bool failUrls = false;

  /// The engine loses its source mid-stream, as a dead connection would.
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
    setUrlCalls.add(url);
    if (failUrls) throw Exception('device not ready after wake');
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seekCalls.add(position);
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _events.close();
  }
}

class _Resolver implements PlayableUriResolver {
  bool reachable = true;
  final List<String> calls = <String>[];
  int _n = 0;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    if (!reachable) {
      throw const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    _n++;
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.uri}?n=$_n'),
      track.uri.startsWith('/')
          ? PlaybackSource.localFile
          : PlaybackSource.streamingDirect,
    );
  }
}

Track _track(String id, String uri) => Track(
      id: id,
      title: 'Song',
      uri: uri,
      artistName: 'Artist',
      albumName: 'Album',
      duration: const Duration(minutes: 3),
    );

Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track local = _track('l', '/music/a.flac');
  final Track remote = _track('r', 'jellyfin:r');
  final Track next = _track('n', 'jellyfin:n');

  LinuxPlaybackController buildLinux({
    required _Engine player,
    required _Resolver resolver,
    required FakeMachineSleep machine,
  }) {
    final controller = LinuxPlaybackController(
      player: player,
      resolver: resolver,
      candidates: const NoFallbackCandidateSource(),
      sleepWatcher: machine.watcher(),
    )
      ..suspendResumeBackoff = Duration.zero
      ..streamRetryBackoff = Duration.zero
      ..midStreamBufferingTimeout = const Duration(hours: 1);
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> startPlaying(
    JustAudioPlaybackController controller,
    Track track,
  ) async {
    await controller.playTracks(<Track>[track, next]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
  }

  /// A suspend of [duration], and the watcher's first look after the wake.
  Future<void> sleepAndWake(
    FakeMachineSleep machine, [
    Duration duration = const Duration(minutes: 30),
  ]) async {
    machine.sleep(duration);
    machine.look();
    await _settle();
  }

  group('Linux reload after a system sleep (#799)', () {
    test('playing across a sleep reloads once at the preserved position',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, remote);
      const Duration preserved = Duration(minutes: 1, seconds: 5);
      controller.setPositionForTesting(preserved);
      expect(player.setUrlCalls, hasLength(1));
      final String firstUrl = player.setUrlCalls.single;

      await sleepAndWake(machine);

      expect(resolver.calls, <String>[remote.uri, remote.uri]);
      expect(player.setUrlCalls, hasLength(2));
      expect(player.setUrlCalls.last, isNot(firstUrl),
          reason: 'a long sleep gets a fresh stream url');
      expect(player.seekCalls, contains(preserved));
      expect(controller.state.currentTrack?.uri, remote.uri);
      expect(controller.state.upNext.map((Track t) => t.uri).toList(),
          <String>[next.uri]);
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('paused across a sleep stays paused, with nothing watching', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, local);
      expect(machine.isWatched, isTrue);
      await controller.pause();
      controller.handleEngineState(PlayerState(false, ProcessingState.ready));
      expect(controller.state.status, PlaybackStatus.paused);
      expect(machine.isWatched, isFalse,
          reason: 'a paused player holds no timer for this');
      final int urlsBefore = player.setUrlCalls.length;
      final int playsBefore = player.playCalls;

      await sleepAndWake(machine);

      expect(player.setUrlCalls.length, urlsBefore);
      expect(player.playCalls, playsBefore);
      expect(controller.state.status, PlaybackStatus.paused);
      expect(controller.state.currentTrack?.uri, local.uri);
    });

    test('a pause just before the sleep holds, even before the engine says so',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, local);
      // The lid closes right after the pause, before the engine reports it.
      await controller.pause();
      final int playsBefore = player.playCalls;

      await sleepAndWake(machine);

      expect(player.setUrlCalls, hasLength(1));
      expect(player.playCalls, playsBefore);
    });

    test('hours awake with the window hidden or minimized reload nothing',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, remote);

      // Time that passes awake moves both clocks, so the watcher sees no
      // gap, however many times it looks.
      for (int i = 0; i < 1800; i++) {
        machine.look();
      }
      await _settle();

      expect(player.setUrlCalls, hasLength(1));
      expect(controller.state.status, PlaybackStatus.playing);
    });

    test('a sleep noticed more than once reloads once', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, remote);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      await sleepAndWake(machine);
      machine.look();
      machine.look();
      await _settle();

      expect(player.setUrlCalls, hasLength(2));
    });

    test('wakes racing the reload wait coalesce into one reload', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);
      controller.suspendResumeBackoff = const Duration(milliseconds: 30);

      await startPlaying(controller, remote);

      // The lid opens and closes again while the reload waits.
      machine.sleep(const Duration(minutes: 5));
      machine.look();
      await _settle();
      machine.sleep(const Duration(seconds: 40));
      machine.look();
      machine.sleep(const Duration(seconds: 40));
      machine.look();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _settle();

      expect(resolver.calls, <String>[remote.uri, remote.uri]);
      expect(player.setUrlCalls, hasLength(2));
    });

    test('a track already reconnected since the wake is not reloaded again',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, remote);

      // The connection died with the network: the engine says so right after
      // the wake, and the reconnect reloads the stream before the watcher's
      // first look.
      machine.sleep(const Duration(minutes: 20));
      player.dropStream();
      await _settle();
      expect(player.setUrlCalls, hasLength(2));
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      expect(controller.state.status, PlaybackStatus.playing);

      machine.look();
      await _settle();

      expect(player.setUrlCalls, hasLength(2),
          reason: 'the stream loaded after the wake has nothing to recover');
    });

    test('a failed reload surfaces the error and keeps the queue', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, remote);
      resolver.reachable = false;

      await sleepAndWake(machine);

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack?.uri, remote.uri);
      expect(controller.state.upNext.map((Track t) => t.uri).toList(),
          <String>[next.uri]);
      expect(controller.state.errorMessage, isNotNull);
      expect(controller.state.errorMessage, isNot(contains('http')));
      expect(machine.isWatched, isFalse,
          reason: 'an error is left to its own recovery, not watched');
    });

    test('repeated sleeps reload once each and never stack', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, local);

      for (int i = 0; i < 3; i++) {
        await sleepAndWake(machine);
        controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      }

      // The first load and one reload per sleep.
      expect(player.setUrlCalls, hasLength(4));
      expect(controller.state.currentTrack?.uri, local.uri);
    });

    test('a sleep while casting reloads nothing locally', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller =
          buildLinux(player: player, resolver: resolver, machine: machine);

      await startPlaying(controller, remote);
      await controller.suspend();
      expect(machine.isWatched, isFalse);

      await sleepAndWake(machine);

      expect(player.setUrlCalls, hasLength(1));
    });

    test('disposing while the reload waits loads nothing and stops looking',
        () async {
      final player = _Engine();
      final resolver = _Resolver();
      final machine = FakeMachineSleep();
      final controller = LinuxPlaybackController(
        player: player,
        resolver: resolver,
        sleepWatcher: machine.watcher(),
      )..suspendResumeBackoff = const Duration(milliseconds: 30);

      await startPlaying(controller, remote);
      await sleepAndWake(machine);
      expect(machine.isWatched, isTrue);
      await controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _settle();

      expect(player.setUrlCalls, hasLength(1));
      expect(machine.isWatched, isFalse);
    });
  });

  group('Android has no reload after a sleep', () {
    test('a playing track is never reloaded on its own', () async {
      final player = _Engine();
      final resolver = _Resolver();
      final controller = JustAudioPlaybackController(
        player: player,
        resolver: resolver,
      )..suspendResumeBackoff = Duration.zero;
      addTearDown(controller.dispose);

      await startPlaying(controller, remote);
      controller.onAppForegrounded();
      await _settle();

      expect(player.setUrlCalls, hasLength(1));
      expect(resolver.calls, <String>[remote.uri]);
    });
  });
}
