import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_browser_tree.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';
import 'package:linthra/core/services/stream_interruption.dart';

import '../../features/library/fake_music_library_repository.dart';

/// A fake engine that records every transport call in order (`setUrl:<url>`,
/// `play`, `pause`, `seek:<ms>`), so a test can read what the engine was last
/// told to do. No platform channel is touched.
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<String> calls = <String>[];

  /// The last play/pause the engine received: what it is doing now.
  String? get lastTransport => calls.lastWhere(
        (String call) => call == 'play' || call == 'pause',
        orElse: () => 'none',
      );

  List<String> get loadedUrls => <String>[
        for (final String call in calls)
          if (call.startsWith('setUrl:')) call.substring('setUrl:'.length),
      ];

  List<String> get seeks => <String>[
        for (final String call in calls)
          if (call.startsWith('seek:')) call,
      ];

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
    calls.add('setUrl:$url');
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) calls.add('seek:${position.inMilliseconds}');
  }

  @override
  Future<void> dispose() async {}
}

/// A resolver whose completion the test releases by hand, so "the listener
/// acts while this track is still resolving" is a deterministic point in the
/// test rather than a timing accident. Uris in [immediate] resolve at once.
class _GatedResolver implements PlayableUriResolver {
  _GatedResolver({Set<String> immediate = const <String>{}})
      : _immediate = immediate;

  final Set<String> _immediate;
  final Map<String, Completer<ResolvedPlayable>> _gates =
      <String, Completer<ResolvedPlayable>>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) {
    if (_immediate.contains(track.uri)) {
      return Future<ResolvedPlayable>.value(_stream(track));
    }
    return _gates
        .putIfAbsent(track.uri, () => Completer<ResolvedPlayable>())
        .future;
  }

  bool isWaiting(String uri) =>
      _gates.containsKey(uri) && !_gates[uri]!.isCompleted;

  void release(Track track) =>
      _gates.remove(track.uri)!.complete(_stream(track));

  void fail(Track track) => _gates.remove(track.uri)!.completeError(
        const PlaybackResolutionException(
          'This file is no longer on the device.',
          kind: PlaybackResolutionErrorKind.localFileMissing,
        ),
      );
}

Track _track(String id, {String provider = 'jellyfin'}) => Track(
      id: id,
      title: id,
      uri: '$provider:$id',
      duration: const Duration(minutes: 3),
    );

String _url(Track track) => 'https://host/stream/${track.uri}';

ResolvedPlayable _stream(Track track) =>
    ResolvedPlayable(Uri.parse(_url(track)), PlaybackSource.streamingDirect);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

AudioInterruptionEvent _begin(AudioInterruptionType type) =>
    AudioInterruptionEvent(true, type);
AudioInterruptionEvent _end(AudioInterruptionType type) =>
    AudioInterruptionEvent(false, type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track a = _track('a');
  final Track b = _track('b');

  /// A controller playing [a] (resolved at once) with [b] next, whose resolve
  /// is gated so the test can act while it is still loading.
  Future<
      ({
        JustAudioPlaybackController controller,
        _RecordingPlayer player,
        _GatedResolver resolver
      })> playingAWithBGated() async {
    final _RecordingPlayer player = _RecordingPlayer();
    final _GatedResolver resolver = _GatedResolver(immediate: <String>{a.uri});
    final JustAudioPlaybackController controller =
        JustAudioPlaybackController(player: player, resolver: resolver);
    controller.focusPauseDebounce = const Duration(milliseconds: 10);
    addTearDown(controller.dispose);
    await controller.playTracks(<Track>[a, b]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    expect(player.lastTransport, 'play');
    return (controller: controller, player: player, resolver: resolver);
  }

  group('a pause issued while a track is loading is kept when it lands', () {
    test('a listener pause during the load leaves the new track paused',
        () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      expect(setup.resolver.isWaiting(b.uri), isTrue);
      expect(setup.controller.state.status, PlaybackStatus.loading);

      // The notification still shows Pause while loading (the session reports
      // a load as playing), and the listener presses it.
      await setup.controller.pause();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.loadedUrls.last, _url(b),
          reason: 'the load still lands, so Play resumes instantly');
      expect(setup.player.lastTransport, 'pause',
          reason: 'the load must not start sound the listener paused');
    });

    test('pause then play during the load ends playing (last intent wins)',
        () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      await setup.controller.pause();
      await setup.controller.play();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.loadedUrls.last, _url(b));
      expect(setup.player.lastTransport, 'play');
    });

    test('play during the load never resumes the song before it', () async {
      final setup = await playingAWithBGated();
      await setup.controller.pause();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      expect(setup.resolver.isWaiting(b.uri), isTrue);

      // Play while b still resolves, from a desktop media key or the shell's
      // media controls (which show a loading track as paused). The engine
      // still holds a.
      await setup.controller.play();
      await _settle();
      expect(setup.player.lastTransport, 'pause',
          reason: "a must not play under b's title");

      setup.resolver.release(b);
      await skip;
      await _settle();
      expect(setup.player.loadedUrls.last, _url(b));
      expect(setup.player.lastTransport, 'play');
    });

    test('headphones unplugged during the load never start the speaker',
        () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      setup.controller.onBecomingNoisyForTesting();
      await _settle();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.lastTransport, 'pause');
    });

    test(
        'a pause during the load survives a call that comes and goes before '
        'it lands', () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      await setup.controller.pause();
      // A call while it still loads, past the debounce, then over.
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.lastTransport, 'pause',
          reason: 'the listener paused; the call ending is no reason to play');
    });

    test('another app taking audio during the load keeps us paused', () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      setup.controller
          .onAudioInterruption(_begin(AudioInterruptionType.unknown));
      await _settle();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.lastTransport, 'pause');
    });

    test(
        'a call that outlasts the debounce during the load stays silent, '
        'and the regain starts the loaded track', () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.lastTransport, 'pause',
          reason: 'no sound while the call holds focus');

      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(setup.player.lastTransport, 'play',
          reason: 'the regain resumes the track that loaded meanwhile');
    });

    test(
        'a call that ends while the next track loads does not resume the '
        'paused song', () async {
      final setup = await playingAWithBGated();
      // Paused, then Next: a request to play B, which is slow to resolve.
      await setup.controller.pause();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      // A call or a notification sound, past the debounce, then over.
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();

      expect(setup.resolver.isWaiting(b.uri), isTrue);
      expect(setup.player.lastTransport, 'pause',
          reason: "the engine still holds A, which the listener paused: the "
              "regain must not play it under B's title");

      setup.resolver.release(b);
      await skip;
      await _settle();
      expect(setup.player.loadedUrls.last, _url(b));
      expect(setup.player.lastTransport, 'play',
          reason: 'B starts once it lands');
    });

    test('a focus blip absorbed during the load still lets the track start',
        () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.lastTransport, 'play');
    });

    test('a skip during a call loads the next track and waits for the regain',
        () async {
      final setup = await playingAWithBGated();
      setup.controller.onAudioInterruption(_begin(AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.loadedUrls.last, _url(b));
      expect(setup.player.lastTransport, 'pause',
          reason: 'nothing starts over the call, as a recovery step would not');

      setup.controller.onAudioInterruption(_end(AudioInterruptionType.pause));
      await _settle();
      expect(setup.player.lastTransport, 'play');
    });

    test('a cast taking over during the load keeps the phone silent', () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      await setup.controller.suspend();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.lastTransport, 'pause',
          reason: 'the receiver plays now; the phone must not play too');
    });

    test('a skip after a pause is a request to play the next track', () async {
      final setup = await playingAWithBGated();
      await setup.controller.pause();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.loadedUrls.last, _url(b));
      expect(setup.player.lastTransport, 'play');
    });
  });

  group('a Play pressed while the restored queue is still loading', () {
    test('starts the restored track when it lands', () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver = _GatedResolver();
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      // Launch puts the last queue back, paused, and its track is still
      // resolving against a slow server when the listener presses Play: a
      // media key or the shell's controls over MPRIS, or the window.
      final Future<void> restore = controller.restoreSession(
        tracks: <Track>[a, b],
        position: const Duration(minutes: 1),
      );
      await _settle();
      expect(resolver.isWaiting(a.uri), isTrue);
      await controller.play();
      resolver.release(a);
      await restore;
      await _settle();

      expect(player.loadedUrls, <String>[_url(a)]);
      expect(player.seeks, <String>['seek:60000'],
          reason: 'it starts where the listener left it');
      expect(player.lastTransport, 'play',
          reason: 'the listener pressed Play while it loaded');
    });

    test('a restore nobody pressed Play for still lands paused', () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver = _GatedResolver();
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      final Future<void> restore = controller.restoreSession(
        tracks: <Track>[a, b],
        position: const Duration(minutes: 1),
      );
      await _settle();
      resolver.release(a);
      await restore;
      await _settle();

      expect(player.loadedUrls, <String>[_url(a)]);
      expect(player.lastTransport, 'none');
    });

    test('Play then Pause while it loads leaves it paused', () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver = _GatedResolver();
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      final Future<void> restore = controller.restoreSession(
        tracks: <Track>[a, b],
        position: const Duration(minutes: 1),
      );
      await _settle();
      await controller.play();
      await controller.pause();
      resolver.release(a);
      await restore;
      await _settle();

      expect(player.loadedUrls, <String>[_url(a)]);
      expect(player.lastTransport, 'pause');
    });
  });

  group('a pause during a mid-stream reconnect is kept', () {
    test('pausing while the retry waits its backoff loads the track paused',
        () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver =
          _GatedResolver(immediate: <String>{a.uri});
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      controller.streamRetryBackoff = const Duration(milliseconds: 20);
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[a]);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      controller.setPositionForTesting(const Duration(seconds: 42));

      controller.handleStreamFailureForTesting(const StreamInterruption(
        StreamInterruptionKind.networkDropped,
        'dropped',
        retryable: true,
      ));
      await _settle();
      expect(controller.state.status, PlaybackStatus.reconnecting);

      await controller.pause();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _settle();

      expect(player.loadedUrls, <String>[_url(a), _url(a)],
          reason: 'the reconnect still reloads the source');
      expect(player.lastTransport, 'pause',
          reason: 'but must not start sound the listener paused');
    });
  });

  group('a seek issued while a track is loading', () {
    test('lands on the loading track at the requested spot', () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      expect(setup.controller.state.currentTrack, b);

      // An MPRIS SetPosition for the loading track (its id matches, and with
      // no duration yet there is no upper bound to reject it).
      await setup.controller.seek(const Duration(seconds: 30));
      setup.resolver.release(b);
      await skip;
      await _settle();

      expect(setup.player.loadedUrls.last, _url(b),
          reason: 'the seek must not abandon the load and strand the old '
              'source under the new title');
      expect(setup.player.seeks.last, 'seek:30000');
      expect(setup.player.lastTransport, 'play');
      expect(setup.controller.state.currentTrack, b);
    });

    test('a seek after the load has started goes straight to the engine',
        () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      setup.resolver.release(b);
      await skip;
      await _settle();

      await setup.controller.seek(const Duration(seconds: 12));

      expect(setup.player.seeks.last, 'seek:12000');
      expect(setup.player.lastTransport, 'play');
    });
  });

  group('Try another source honours what happens during its load', () {
    final Track jellyfinX = _track('x');
    final Track subsonicX = _track('x', provider: 'subsonic');

    /// [jellyfinX] failed with no other copy known at the time; [subsonicX]
    /// has since appeared (a sync finished), and its resolve is gated.
    Future<
        ({
          JustAudioPlaybackController controller,
          _RecordingPlayer player,
          _GatedResolver resolver
        })> failedWithAnotherCopy() async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver = _GatedResolver();
      final Map<String, List<Track>> copies = <String, List<Track>>{};
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: player,
        resolver: resolver,
        candidates: MapPlaybackCandidateSource(() => copies),
      );
      addTearDown(controller.dispose);
      final Future<void> play = controller.playTracks(<Track>[jellyfinX]);
      await _settle();
      resolver.fail(jellyfinX);
      await play;
      expect(controller.state.status, PlaybackStatus.error);
      copies[jellyfinX.uri] = <Track>[jellyfinX, subsonicX];
      return (controller: controller, player: player, resolver: resolver);
    }

    test('a pause while the other copy loads leaves it paused', () async {
      final setup = await failedWithAnotherCopy();
      final Future<void> attempt = setup.controller.tryAnotherSource();
      await _settle();
      expect(setup.resolver.isWaiting(subsonicX.uri), isTrue);

      await setup.controller.pause();
      setup.resolver.release(subsonicX);
      await attempt;
      await _settle();

      expect(setup.player.loadedUrls.last, _url(subsonicX));
      expect(setup.player.lastTransport, 'pause');
    });

    test('a seek while the other copy loads lands there instead of stalling',
        () async {
      final setup = await failedWithAnotherCopy();
      final Future<void> attempt = setup.controller.tryAnotherSource();
      await _settle();

      await setup.controller.seek(const Duration(seconds: 20));
      setup.resolver.release(subsonicX);
      await attempt;
      await _settle();

      expect(setup.player.loadedUrls.last, _url(subsonicX),
          reason: 'the seek used to abandon this load and leave the player '
              'on Loading for good');
      expect(setup.player.seeks.last, 'seek:20000');
      expect(setup.player.lastTransport, 'play');
      expect(setup.controller.state.currentTrack?.uri, subsonicX.uri);
    });
  });

  group('automatic recovery respects a pause made during the load', () {
    test('a load that fails after a pause shows the failure, not the next song',
        () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver =
          _GatedResolver(immediate: <String>{b.uri});
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: player,
        resolver: resolver,
        automaticRecovery: const PlaybackRecoveryPolicy(
          retryDelay: Duration.zero,
          advanceDelay: Duration.zero,
          maxAdvanceDelay: Duration.zero,
        ),
      );
      addTearDown(controller.dispose);

      final Future<void> play = controller.playTracks(<Track>[a, b]);
      await _settle();
      await controller.pause();
      resolver.fail(a);
      await play;
      for (int i = 0; i < 20; i++) {
        await _settle();
      }

      expect(controller.state.status, PlaybackStatus.error,
          reason: 'the listener paused: the failure waits for them');
      expect(controller.state.currentTrack, a);
      expect(controller.hasPendingAutomaticRecovery, isFalse);
      expect(player.loadedUrls, isNot(contains(_url(b))),
          reason: 'nothing moves along the queue behind a pause');
    });
  });

  group('the post-suspend reload respects a pause during its backoff', () {
    test('pausing before the reload runs loads the track paused', () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver =
          _GatedResolver(immediate: <String>{a.uri});
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: player,
        resolver: resolver,
        recoverPlaybackAfterSuspend: true,
      )..suspendResumeBackoff = const Duration(milliseconds: 20);
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[a]);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));

      controller.onAppBackgrounded();
      controller.onAppForegrounded();
      // A media key or the desktop shell pauses while the wake reload waits.
      await controller.pause();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _settle();

      expect(player.loadedUrls, <String>[_url(a), _url(a)],
          reason: 'the reload still refreshes the source after sleep');
      expect(player.lastTransport, 'pause');
    });
  });

  // #751: the media session reads a busy state as playing only while the
  // listener still wants sound, so every state carries that intent.
  group('the intent the media session reads (#751)', () {
    test('a pause during a mid-stream stall is published at once', () async {
      final setup = await playingAWithBGated();
      // The stream stalls while playing.
      setup.controller
          .handleEngineState(PlayerState(true, ProcessingState.buffering));
      expect(setup.controller.state.status, PlaybackStatus.buffering);
      expect(setup.controller.state.playWhenReady, isTrue);

      await setup.controller.pause();
      expect(setup.controller.state.playWhenReady, isFalse,
          reason: 'the stalled engine may say nothing new for a long while');

      // The engine's own report of the pause: still buffering, not playing.
      setup.controller
          .handleEngineState(PlayerState(false, ProcessingState.buffering));
      expect(setup.controller.state.status, PlaybackStatus.loading);
      expect(setup.controller.state.playWhenReady, isFalse);

      // Play while it is still stalled.
      await setup.controller.play();
      expect(setup.controller.state.playWhenReady, isTrue);
    });

    test('a pause while the next track loads is published before it lands',
        () async {
      final setup = await playingAWithBGated();
      final Future<void> skip = setup.controller.skipToNext();
      await _settle();
      expect(setup.controller.state.status, PlaybackStatus.loading);
      expect(setup.controller.state.playWhenReady, isTrue);

      await setup.controller.pause();
      // The engine's report is about a, on its way out, and is dropped.
      setup.controller
          .handleEngineState(PlayerState(false, ProcessingState.ready));
      expect(setup.controller.state.status, PlaybackStatus.loading);
      expect(setup.controller.state.playWhenReady, isFalse);

      setup.resolver.release(b);
      await skip;
      await _settle();
      expect(setup.player.lastTransport, 'pause');
    });

    test('a restored queue opens as not meant to play', () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver = _GatedResolver();
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      final Future<void> restore = controller.restoreSession(
        tracks: <Track>[a, b],
        position: const Duration(minutes: 1),
      );
      await _settle();
      expect(controller.state.status, PlaybackStatus.loading);
      expect(controller.state.playWhenReady, isFalse,
          reason: 'nobody asked this load to play');

      await controller.play();
      expect(controller.state.playWhenReady, isTrue);

      resolver.release(a);
      await restore;
    });

    test('a load after a paused cast ends is not meant to play either',
        () async {
      final _RecordingPlayer player = _RecordingPlayer();
      final _GatedResolver resolver =
          _GatedResolver(immediate: <String>{a.uri});
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);
      await controller.playTracks(<Track>[a, b]);
      controller.handleEngineState(PlayerState(true, ProcessingState.ready));
      await controller.suspend();
      // The receiver moved on to b, then the cast ended paused.
      await controller.skipToNext();
      final Future<void> resumed = controller.resume();
      await _settle();
      expect(controller.state.status, PlaybackStatus.loading);
      expect(controller.state.playWhenReady, isFalse);

      resolver.release(b);
      await resumed;
      expect(player.lastTransport, isNot('play'));
    });

    test('the Android session reports a paused stall as paused end to end',
        () async {
      final setup = await playingAWithBGated();
      final LinthraAudioHandler handler = LinthraAudioHandler(
        setup.controller,
        MediaBrowserTree(FakeMusicLibraryRepository(tracks: <Track>[a, b])),
      );
      addTearDown(handler.dispose);
      setup.controller
          .handleEngineState(PlayerState(true, ProcessingState.buffering));
      await _settle();
      expect(handler.playbackState.value.playing, isTrue,
          reason: 'a stall during playback keeps the service up');

      // The listener taps Pause in the notification mid-stall.
      await handler.pause();
      setup.controller
          .handleEngineState(PlayerState(false, ProcessingState.buffering));
      await _settle();

      final audio.PlaybackState session = handler.playbackState.value;
      expect(session.playing, isFalse);
      expect(session.processingState, audio.AudioProcessingState.ready);
      expect(session.controls, contains(audio.MediaControl.play));

      // A headset click now plays rather than pausing again.
      await handler.click();
      await _settle();
      expect(setup.player.lastTransport, 'play');
      expect(handler.playbackState.value.playing, isTrue);
    });
  });
}
