import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

class _Engine extends Fake implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  final events = StreamController<PlaybackEvent>.broadcast(sync: true);
  final List<String> opened = <String>[];
  final List<Duration> seeks = <Duration>[];
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  int disposals = 0;
  bool failOpen = false;

  /// The streams whose connection drops while libmpv is still opening them
  /// (the reconnect is refused). The vendored just_audio_media_kit reports
  /// that only as an idle engine with an error code, and just_audio lets the
  /// engine go on that idle without ever answering the load, so setUrl
  /// never returns (seen natively with libmpv 2.2).
  final Set<String> dropWhileOpening = <String>{};

  /// How long an open takes to answer when it answers.
  Duration openDelay = Duration.zero;

  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;

  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    opened.add(url);
    if (failOpen) throw Exception('native open failed with a secret URL');
    if (dropWhileOpening.contains(url)) {
      states.add(PlayerState(false, ProcessingState.loading));
      states.add(PlayerState(false, ProcessingState.idle));
      return Completer<Duration?>().future;
    }
    if (openDelay > Duration.zero) await Future<void>.delayed(openDelay);
    return const Duration(minutes: 4);
  }

  @override
  Future<void> play() async {
    plays++;
    states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    pauses++;
    states.add(PlayerState(false, ProcessingState.ready));
  }

  /// What just_audio does on stop: the player stops playing, and the platform
  /// it switches to reports idle.
  @override
  Future<void> stop() async {
    stops++;
    states.add(PlayerState(false, ProcessingState.ready));
    states.add(PlayerState(false, ProcessingState.idle));
  }

  /// libmpv loses the source mid-playback (a server that went away, a
  /// truncated stream, a file it cannot decode further). The vendored
  /// just_audio_media_kit reports that as an idle engine with an error code,
  /// which just_audio does not forward: nothing arrives on
  /// [playbackEventStream], only the idle state.
  void loseSourceAsLinuxDoes() {
    states.add(PlayerState(true, ProcessingState.idle));
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) seeks.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async => disposals++;

  Future<void> close() async {
    await states.close();
    await positions.close();
    await durations.close();
    await events.close();
  }
}

class _Resolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    if (track.uri.startsWith('/')) {
      return ResolvedPlayable(Uri.file(track.uri), PlaybackSource.localFile);
    }
    return ResolvedPlayable(
      Uri.parse('https://music.example/stream/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

Track _track(String id, String uri) => Track(id: id, title: id, uri: uri);

void main() {
  group('linuxMpvProperties', () {
    test('turns off mpv\'s on-disk packet cache', () {
      expect(resolveLinuxMpvProperties(const {})['cache-on-disk'], 'no');
    });

    test('never disables mpv caching wholesale', () {
      // media_kit sets `cache=yes`; only the on-disk packet file is the
      // problem, so a broad `cache=no` would cost normal network buffering.
      expect(
        resolveLinuxMpvProperties(const {}).keys,
        <String>['cache-on-disk', 'ytdl'],
      );
    });

    test('never hands a stream URL to youtube-dl', () {
      // mpv passes an HTTP URL it fails to open to yt-dlp as an argument,
      // and a Subsonic or Plex stream URL carries the account's token.
      expect(resolveLinuxMpvProperties(const {})['ytdl'], 'no');
      expect(
        resolveLinuxMpvProperties(const {'ao': 'null'})['ytdl'],
        'no',
      );
    });

    test('keeps what a caller already configured, and adds the defaults', () {
      // The headless audio smoke picks the output device this way.
      final resolved = resolveLinuxMpvProperties(const {'ao': 'null'});

      expect(resolved['ao'], 'null');
      expect(resolved['cache-on-disk'], 'no');
    });

    test('lets an explicit caller value win over a default', () {
      expect(
        resolveLinuxMpvProperties(const {'cache-on-disk': 'yes'}),
        containsPair('cache-on-disk', 'yes'),
      );
    });
  });

  group('LinuxPlaybackBackendInitializer', () {
    test('registers the backend exactly once after successful initialization',
        () {
      var registrations = 0;
      final initializer = LinuxPlaybackBackendInitializer(
        registerBackend: () => registrations++,
      );

      initializer.ensureInitialized();
      initializer.ensureInitialized();

      expect(registrations, 1);
    });

    test('allows a later attempt to retry after initialization throws', () {
      var registrations = 0;
      final initializer = LinuxPlaybackBackendInitializer(
        registerBackend: () {
          if (++registrations == 1) throw StateError('initialization failed');
        },
      );

      expect(initializer.ensureInitialized, throwsStateError);
      expect(initializer.ensureInitialized, returnsNormally);
      expect(registrations, 2);
    });
  });
  LinuxPlaybackController build(_Engine engine, {Random? random}) =>
      LinuxPlaybackController(
        player: engine,
        resolver: _Resolver(),
        random: random,
      );

  test('opens local files and remote resolver URLs through the same engine',
      () async {
    final engine = _Engine();
    final controller = build(engine);
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });

    await controller.playTrack(_track('local', '/music/song.flac'));
    await controller.playTrack(_track('remote', 'jellyfin:remote'));

    expect(engine.opened, <String>[
      Uri.file('/music/song.flac').toString(),
      'https://music.example/stream/remote',
    ]);
    expect(controller.state.source, PlaybackSource.streamingDirect);
    expect(controller.state.status, PlaybackStatus.playing);
  });

  test('play, pause, seek and stop delegate and keep state truthful', () async {
    final engine = _Engine();
    final controller = build(engine);
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });

    await controller.playTrack(_track('a', '/a.mp3'));
    await controller.pause();
    await controller.seek(const Duration(seconds: 37));
    await controller.play();
    await controller.stop();

    expect(engine.pauses, 1);
    expect(engine.seeks, <Duration>[const Duration(seconds: 37)]);
    expect(engine.plays, 2);
    expect(engine.stops, 1);
    expect(controller.state.status, PlaybackStatus.idle);
  });

  test(
      'queue replacement, next/previous and shuffle/repeat stay controller-owned',
      () async {
    final engine = _Engine();
    final controller = build(engine, random: Random(7));
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    final tracks = <Track>[
      _track('a', '/a.mp3'),
      _track('b', '/b.mp3'),
      _track('c', '/c.mp3'),
    ];

    await controller.playTracks(tracks);
    await controller.skipToNext();
    await controller.skipToPrevious();
    controller.setShuffleEnabled(true);
    controller.setRepeatMode(RepeatMode.all);

    expect(controller.state.currentTrack, tracks.first);
    expect(controller.state.shuffleEnabled, isTrue);
    expect(controller.state.repeatMode, RepeatMode.all);
    expect(controller.state.upNext, hasLength(2));
  });

  test('completion advances and a native open error never claims playing',
      () async {
    final engine = _Engine();
    final controller = build(engine);
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    await controller.playTracks(<Track>[
      _track('a', '/a.mp3'),
      _track('b', '/b.mp3'),
    ]);

    engine.states.add(PlayerState(false, ProcessingState.completed));
    await pumpEventQueue();
    expect(controller.state.currentTrack?.id, 'b');

    engine.failOpen = true;
    await controller.playTrack(_track('broken', 'plex:broken'));
    expect(controller.state.status, PlaybackStatus.error);
    expect(controller.state.isPlaying, isFalse);
    expect(controller.state.errorMessage, isNot(contains('music.example')));
  });

  test('a stream lost mid-song is recovered, not left playing in silence',
      () async {
    final engine = _Engine();
    final controller = build(engine)..streamRetryBackoff = Duration.zero;
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    await controller.playTrack(_track('remote', 'jellyfin:remote'));
    expect(controller.state.status, PlaybackStatus.playing);

    engine.loseSourceAsLinuxDoes();
    await pumpEventQueue();

    // The same bounded recovery an engine error gets: the stream is opened
    // again, where it was.
    expect(engine.opened, <String>[
      'https://music.example/stream/remote',
      'https://music.example/stream/remote',
    ]);
    expect(controller.state.status, PlaybackStatus.playing);
  });

  test('a local file lost mid-song says so instead of playing in silence',
      () async {
    final engine = _Engine();
    final controller = build(engine);
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    // Not on this disk any more: its drive was pulled out mid-song.
    await controller.playTrack(_track('gone', '/linthra-test/gone.flac'));
    expect(controller.state.status, PlaybackStatus.playing);

    engine.loseSourceAsLinuxDoes();
    await pumpEventQueue();

    expect(controller.state.status, PlaybackStatus.error);
    expect(controller.state.isPlaying, isFalse);
  });

  test('stopping is not taken for a lost source', () async {
    final engine = _Engine();
    final controller = build(engine)..streamRetryBackoff = Duration.zero;
    addTearDown(() async {
      await controller.dispose();
      await engine.close();
    });
    await controller.playTrack(_track('remote', 'jellyfin:remote'));

    await controller.stop();
    await pumpEventQueue();

    expect(engine.opened, hasLength(1));
    expect(controller.state.status, PlaybackStatus.idle);
  });

  group('a stream that drops while it opens', () {
    testWidgets('ends on a failure to retry instead of loading for good',
        (WidgetTester tester) async {
      final engine = _Engine()
        ..dropWhileOpening.add('https://music.example/stream/remote');
      final controller = build(engine);
      addTearDown(() async {
        await controller.dispose();
        await engine.close();
      });

      unawaited(controller.playTrack(_track('remote', 'jellyfin:remote')));
      await tester.pump();
      expect(controller.state.status, PlaybackStatus.loading);

      await tester.pump(const Duration(seconds: 31));

      // Play does nothing while a load is in flight, so a spinner that never
      // ends leaves the listener nothing to do but skip.
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canRetry, isTrue);

      engine.dropWhileOpening.clear();
      await controller.retryCurrentTrack();
      expect(controller.state.status, PlaybackStatus.playing);
    });

    testWidgets('an open that answers in time is not cut short',
        (WidgetTester tester) async {
      final engine = _Engine()..openDelay = const Duration(seconds: 25);
      final controller = build(engine);
      addTearDown(() async {
        await controller.dispose();
        await engine.close();
      });

      unawaited(controller.playTrack(_track('remote', 'jellyfin:remote')));
      await tester.pump(const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 10));

      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.opened, hasLength(1));
    });

    testWidgets('leaves the song picked after it alone',
        (WidgetTester tester) async {
      final engine = _Engine()
        ..dropWhileOpening.add('https://music.example/stream/a');
      final controller = build(engine);
      addTearDown(() async {
        await controller.dispose();
        await engine.close();
      });

      unawaited(controller.playTracks(<Track>[
        _track('a', 'jellyfin:a'),
        _track('b', 'jellyfin:b'),
      ]));
      await tester.pump();
      await controller.skipToNext();
      expect(controller.state.status, PlaybackStatus.playing);

      await tester.pump(const Duration(seconds: 31));

      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.state.status, PlaybackStatus.playing);
      expect(engine.pauses, 0);
    });
  });

  // libmpv 2.2, seen natively: a seek to the very end while paused reports
  // nothing, and Play then reports playing (ready) with libmpv sitting at the
  // end, never reaching an end it would report.
  group('a paused seek to the end', () {
    Future<LinuxPlaybackController> pausedAtTheEndOfA(
      _Engine engine,
      Duration target,
      List<Track> completed,
    ) async {
      final LinuxPlaybackController controller = LinuxPlaybackController(
        player: engine,
        resolver: _Resolver(),
        onTrackCompleted: completed.add,
      );
      await controller.playTracks(<Track>[
        _track('a', '/a.mp3'),
        _track('b', '/b.mp3'),
      ]);
      engine.durations.add(const Duration(minutes: 4));
      await controller.pause();
      await controller.seek(target);
      return controller;
    }

    test('then Play moves on to the next track', () async {
      final engine = _Engine();
      final List<Track> completed = <Track>[];
      final controller = await pausedAtTheEndOfA(
          engine, const Duration(minutes: 4), completed);
      addTearDown(() async {
        await controller.dispose();
        await engine.close();
      });

      await controller.play();
      await pumpEventQueue();

      expect(completed.map((Track t) => t.id), <String>['a']);
      expect(controller.state.currentTrack?.id, 'b');
      expect(engine.opened, hasLength(2));
    });

    test('past the end does the same', () async {
      final engine = _Engine();
      final List<Track> completed = <Track>[];
      final controller = await pausedAtTheEndOfA(
          engine, const Duration(minutes: 5), completed);
      addTearDown(() async {
        await controller.dispose();
        await engine.close();
      });

      await controller.play();
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 'b');
    });

    test('a seek back before Play plays on from there', () async {
      final engine = _Engine();
      final List<Track> completed = <Track>[];
      final controller = await pausedAtTheEndOfA(
          engine, const Duration(minutes: 4), completed);
      addTearDown(() async {
        await controller.dispose();
        await engine.close();
      });
      await controller.seek(const Duration(minutes: 3));

      await controller.play();
      await pumpEventQueue();

      expect(completed, isEmpty);
      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.state.status, PlaybackStatus.playing);
    });
  });

  test('dispose releases the engine and a fresh controller can play', () async {
    final firstEngine = _Engine();
    final first = build(firstEngine);
    await first.dispose();
    expect(firstEngine.disposals, 1);
    await firstEngine.close();

    final secondEngine = _Engine();
    final second = build(secondEngine);
    await second.playTrack(_track('again', '/again.ogg'));
    expect(second.state.status, PlaybackStatus.playing);
    await second.dispose();
    await secondEngine.close();
  });
}
