import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_browser_tree.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';

import '../../features/library/fake_music_library_repository.dart';

/// An engine that opens whatever it is handed and records what it loaded.
class _Engine extends Fake implements AudioPlayer {
  final List<String> loaded = <String>[];

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

/// Resolves every track except the ones marked down, counting attempts.
class _Resolver implements PlayableUriResolver {
  final Set<String> down = <String>{};
  final Map<String, int> attempts = <String, int>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    attempts.update(track.uri, (int n) => n + 1, ifAbsent: () => 1);
    if (down.contains(track.uri)) {
      throw const PlaybackResolutionException(
        "Couldn't reach your music server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    return ResolvedPlayable(Uri.parse(_url(track)), PlaybackSource.localFile);
  }
}

Track _track(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

String _url(Track track) => 'file:///music/${track.id}';

/// Short enough to wait out in a test, long enough to act inside.
const Duration _countdown = Duration(milliseconds: 80);

const PlaybackRecoveryPolicy _policy = PlaybackRecoveryPolicy(
  retryDelay: Duration.zero,
  advanceDelay: _countdown,
  maxAdvanceDelay: _countdown,
);

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _pastCountdown() async {
  await Future<void>.delayed(_countdown * 2);
  await _settle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track a = _track('a');
  final Track b = _track('b');
  final Track c = _track('c');

  late _Engine engine;
  late _Resolver resolver;

  JustAudioPlaybackController build({bool autoSkip = true, Random? random}) {
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: engine,
      resolver: resolver,
      automaticRecovery: _policy,
      random: random,
    )..setAutomaticSkipEnabled(autoSkip);
    addTearDown(controller.dispose);
    return controller;
  }

  /// Plays [queue] with [a] down, and waits until its retry has been spent,
  /// which is when the countdown (or, with automatic skip off, the stop)
  /// happens.
  Future<void> failA(
    JustAudioPlaybackController controller, {
    List<Track>? queue,
  }) async {
    resolver.down.add(a.uri);
    await controller.playTracks(queue ?? <Track>[a, b, c]);
    await _settle();
  }

  setUp(() {
    engine = _Engine();
    resolver = _Resolver();
  });

  /// The media session the notification, headsets and Android Auto drive.
  LinthraAudioHandler handlerFor(JustAudioPlaybackController controller) {
    final LinthraAudioHandler handler = LinthraAudioHandler(
      controller,
      MediaBrowserTree(FakeMusicLibraryRepository(tracks: <Track>[a, b, c])),
    );
    addTearDown(handler.dispose);
    return handler;
  }

  group('with automatic skip off (the default until the listener allows it)',
      () {
    test('still retries, then stops on the failed track with its reason',
        () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();

      expect(resolver.attempts[a.uri], 2,
          reason: 'the bounded retry is not the skip, and still runs');
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack, a);
      expect(
          controller.state.failure?.kind, PlaybackFailureKind.temporarySource);
      expect(controller.state.failure?.canSkip, isTrue,
          reason: 'Skip stays the listener\'s to press');
      expect(controller.state.autoSkip, isNull);
      expect(engine.loaded, isEmpty, reason: 'nothing moved along the queue');
    });

    test('a fresh controller is off without being told', () async {
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: resolver,
        automaticRecovery: _policy,
      );
      addTearDown(controller.dispose);
      await failA(controller);
      await _pastCountdown();

      expect(controller.state.status, PlaybackStatus.error);
      expect(engine.loaded, isEmpty);
    });
  });

  group('with automatic skip on', () {
    test('publishes the reason and a countdown, then moves on once', () async {
      final JustAudioPlaybackController controller = build();
      final List<PlaybackState> seen = <PlaybackState>[];
      final StreamSubscription<PlaybackState> sub =
          controller.stateStream.listen(seen.add);
      addTearDown(sub.cancel);
      final DateTime before = DateTime.now();

      await failA(controller);

      final PendingAutoSkip? pending = controller.state.autoSkip;
      expect(pending, isNotNull);
      expect(pending!.failure.kind, PlaybackFailureKind.temporarySource);
      expect(pending.failure.message, "Couldn't reach your music server.");
      expect(pending.countdown, _countdown);
      expect(pending.skipsAt.isAfter(before), isTrue);
      expect(controller.state.currentTrack, a);
      expect(controller.state.isBusy, isTrue,
          reason: 'a busy status keeps the media service up for the timer');
      expect(engine.loaded, isEmpty, reason: 'nothing moves before the end');

      await _pastCountdown();

      expect(controller.state.currentTrack, b);
      expect(controller.state.autoSkip, isNull);
      expect(engine.loaded, <String>[_url(b)],
          reason: 'exactly one move, to the next playable track');
      expect(seen.any((PlaybackState s) => s.autoSkip != null), isTrue,
          reason: 'listeners saw the countdown the controller ran');
    });

    test('Stay on this track calls it off and shows the failure', () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);
      expect(controller.state.autoSkip, isNotNull);

      await controller.cancelAutomaticSkip();
      await _pastCountdown();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack, a);
      expect(controller.state.failure, isNotNull);
      expect(controller.state.autoSkip, isNull);
      expect(engine.loaded, isEmpty, reason: 'the skip must not still happen');

      // A late second tap is harmless.
      await controller.cancelAutomaticSkip();
      expect(controller.state.status, PlaybackStatus.error);
    });

    test('Next during the countdown moves once, to where the listener went',
        () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);

      await controller.skipToNext();
      await _pastCountdown();

      expect(controller.state.currentTrack, b);
      expect(engine.loaded, <String>[_url(b)],
          reason: 'the countdown must not add a second move after the Next');
    });

    test('a pause during the countdown stops it on the failure', () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);

      await controller.pause();
      await _pastCountdown();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.autoSkip, isNull);
      expect(engine.loaded, isEmpty);
    });

    test('a new queue during the countdown replaces it', () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);

      await controller.playTracks(<Track>[c]);
      await _pastCountdown();

      expect(controller.state.currentTrack, c);
      expect(engine.loaded, <String>[_url(c)]);
    });

    test('turning the setting off mid-countdown stops on the failure',
        () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);

      controller.setAutomaticSkipEnabled(false);
      await _pastCountdown();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.autoSkip, isNull);
      expect(engine.loaded, isEmpty);
    });

    test('turning it on after a stop does not skip retroactively', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();

      controller.setAutomaticSkipEnabled(true);
      await _pastCountdown();

      expect(controller.state.status, PlaybackStatus.error);
      expect(engine.loaded, isEmpty);
    });

    test('repeat-all wraps past the last track to the first', () async {
      final JustAudioPlaybackController controller = build()
        ..setRepeatMode(RepeatMode.all);
      resolver.down.add(c.uri);
      await controller.playTracks(<Track>[a, b, c], startIndex: 2);
      await _settle();
      expect(controller.state.autoSkip, isNotNull);

      await _pastCountdown();

      expect(controller.state.currentTrack, a);
      expect(engine.loaded, <String>[_url(a)]);
    });

    test('repeat-one never counts down: the listener asked for this track',
        () async {
      final JustAudioPlaybackController controller = build()
        ..setRepeatMode(RepeatMode.one);
      await failA(controller);

      expect(controller.state.autoSkip, isNull);
      expect(controller.state.status, PlaybackStatus.error);
      await _pastCountdown();
      expect(engine.loaded, isEmpty);
    });

    test('shuffle moves to the next track in the shuffled order', () async {
      final JustAudioPlaybackController controller = build()
        ..setShuffleEnabled(true);
      resolver.down.add(a.uri);
      await controller.playTracks(<Track>[a, b, c]);
      await _settle();
      final Track expected = controller.state.upNext.first;

      await _pastCountdown();

      expect(controller.state.currentTrack, expected);
      expect(engine.loaded, <String>[_url(expected)]);
    });

    test('a skip onto a song queued twice keeps that copy for shuffle off',
        () async {
      // [b, a, b, c] from a, shuffled to [a, b₂, b₀, c]: the skip lands on
      // the copy of b from the end of the original order.
      final JustAudioPlaybackController controller = build(random: Random(13))
        ..setShuffleEnabled(true);
      resolver.down.add(a.uri);
      await controller.playTracks(<Track>[b, a, b, c], startIndex: 1);
      await _settle();

      await _pastCountdown();
      expect(controller.state.currentTrack, b);

      controller.setShuffleEnabled(false);

      expect(controller.state.previous, <Track>[b, a]);
      expect(controller.state.upNext, <Track>[c]);
    });
  });

  group('before the saved choice has been read', () {
    JustAudioPlaybackController untold() {
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: resolver,
        automaticRecovery: _policy,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('a failure that stopped meanwhile counts down once it reads on',
        () async {
      // A play from the car or MPRIS right at startup, failing before the
      // preference has come back.
      final JustAudioPlaybackController controller = untold();
      await failA(controller);
      await _pastCountdown();
      expect(controller.state.status, PlaybackStatus.error);

      controller.setAutomaticSkipEnabled(true);

      expect(controller.state.autoSkip, isNotNull,
          reason: 'the countdown it would have had');
      await _pastCountdown();
      expect(controller.state.currentTrack, b);
      expect(engine.loaded, <String>[_url(b)]);
    });

    test('stays stopped when the saved choice reads off', () async {
      final JustAudioPlaybackController controller = untold();
      await failA(controller);
      await _pastCountdown();

      controller.setAutomaticSkipEnabled(false);
      controller.setAutomaticSkipEnabled(true);
      await _pastCountdown();

      expect(controller.state.status, PlaybackStatus.error);
      expect(engine.loaded, isEmpty,
          reason: 'turning it on later never skips a stopped track');
    });

    test('a held failure whose next track was removed does not count down',
        () async {
      final JustAudioPlaybackController controller = untold();
      await failA(controller, queue: <Track>[a, b]);
      await _pastCountdown();
      controller.removeFromQueue(0);

      controller.setAutomaticSkipEnabled(true);

      expect(controller.state.autoSkip, isNull,
          reason: 'nowhere to go, so no skip may be promised');
      expect(controller.state.status, PlaybackStatus.error);
      await _pastCountdown();
      expect(engine.loaded, isEmpty);
    });

    test('a held failure does not count down under a cast', () async {
      final JustAudioPlaybackController controller = untold();
      await failA(controller);
      await _pastCountdown();
      await controller.suspend();

      controller.setAutomaticSkipEnabled(true);

      expect(controller.state.autoSkip, isNull,
          reason: 'the receiver owns playback; no local skip to promise');
      await _pastCountdown();
      expect(engine.loaded, isEmpty);
    });

    test('a failure the listener has acted on since stays theirs', () async {
      final JustAudioPlaybackController controller = untold();
      await failA(controller);
      await _pastCountdown();
      await controller.pause();

      controller.setAutomaticSkipEnabled(true);
      await _pastCountdown();

      expect(controller.state.autoSkip, isNull);
      expect(engine.loaded, isEmpty);
    });
  });

  group('a countdown whose target goes away', () {
    test('removing the track it would land on calls it off at once', () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller, queue: <Track>[a, b]);
      expect(controller.state.autoSkip, isNotNull);

      controller.removeFromQueue(0);

      expect(controller.state.autoSkip, isNull,
          reason: 'no skip is coming, so none may be promised');
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack, a);
      expect(controller.state.failure?.canSkip, isFalse);
      await _pastCountdown();
      expect(engine.loaded, isEmpty);
    });

    test('clearing the queue calls it off at once', () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);

      controller.clearQueue();

      expect(controller.state.autoSkip, isNull);
      expect(controller.state.status, PlaybackStatus.error);
      await _pastCountdown();
      expect(engine.loaded, isEmpty);
    });

    test('switching to repeat-one calls it off at once', () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);

      controller.setRepeatMode(RepeatMode.one);

      expect(controller.state.autoSkip, isNull);
      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.repeatMode, RepeatMode.one);
      await _pastCountdown();
      expect(engine.loaded, isEmpty);
    });

    test('a countdown that still has somewhere to go carries on', () async {
      final JustAudioPlaybackController controller = build();
      await failA(controller);

      controller.removeFromQueue(0);
      expect(controller.state.autoSkip, isNotNull);
      await _pastCountdown();

      expect(controller.state.currentTrack, c);
      expect(engine.loaded, <String>[_url(c)]);
    });
  });

  group('Allow automatic skip, from the question on a failed track', () {
    test('a failure says when automatic skip could move on', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false)
        ..setRepeatMode(RepeatMode.all);
      // Last in a repeat-all queue: Skip follows the queue and has nowhere to
      // go, but an automatic skip wraps to the start.
      resolver.down.add(c.uri);
      await controller.playTracks(<Track>[a, b, c], startIndex: 2);
      await _pastCountdown();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.failure?.canSkip, isFalse);
      expect(controller.state.failure?.canAutoSkip, isTrue);
    });

    test('nor under repeat-one, which never moves', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false)
        ..setRepeatMode(RepeatMode.one);
      await failA(controller);
      await _pastCountdown();

      expect(controller.state.failure?.canSkip, isTrue);
      expect(controller.state.failure?.canAutoSkip, isFalse);
    });

    test('moves past the failed track where an automatic skip would go',
        () async {
      final JustAudioPlaybackController controller = build(autoSkip: false)
        ..setRepeatMode(RepeatMode.all);
      resolver.down.add(c.uri);
      await controller.playTracks(<Track>[a, b, c], startIndex: 2);
      await _pastCountdown();

      controller.setAutomaticSkipEnabled(true);
      await controller.skipPastFailedTrack(c);
      await _settle();

      expect(controller.state.currentTrack, a);
      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(engine.loaded, <String>[_url(a)]);
    });

    test('waits for the choice to be saved, then moves', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();
      final Completer<void> saved = Completer<void>();

      final Future<void> moving =
          controller.skipPastFailedTrack(a, after: saved.future);
      await _settle();
      expect(controller.state.currentTrack, a, reason: 'not saved yet');
      // The save landing publishes "on", which the app hands to playback.
      controller.setAutomaticSkipEnabled(true);
      saved.complete();
      await moving;
      await _settle();

      expect(controller.state.currentTrack, b);
      expect(engine.loaded, <String>[_url(b)]);
    });

    test('a save that fails moves nothing, and says so', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();

      await expectLater(
        controller.skipPastFailedTrack(
          a,
          after: Future<void>.error(StateError('disk full')),
        ),
        throwsStateError,
      );
      await _settle();

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.currentTrack, a);
      expect(engine.loaded, isEmpty);
    });

    test('a Retry while the choice is saved is the listener\'s', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();
      final Completer<void> saved = Completer<void>();
      final Future<void> moving =
          controller.skipPastFailedTrack(a, after: saved.future);

      // The panel is gone at once; the listener retries, and it fails again
      // on the same track.
      await controller.retryCurrentTrack();
      await _pastCountdown();
      expect(controller.state.status, PlaybackStatus.error);
      // The save landing publishes "on", which the app hands to playback.
      controller.setAutomaticSkipEnabled(true);
      saved.complete();
      await moving;
      await _settle();

      expect(controller.state.currentTrack, a,
          reason: 'the late move must not override the Retry');
      expect(engine.loaded, isEmpty);
    });

    test('a pause while the choice is saved holds', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();
      final Completer<void> saved = Completer<void>();
      final Future<void> moving =
          controller.skipPastFailedTrack(a, after: saved.future);

      await controller.pause();
      // The save landing publishes "on", which the app hands to playback.
      controller.setAutomaticSkipEnabled(true);
      saved.complete();
      await moving;
      await _settle();

      expect(controller.state.currentTrack, a);
      expect(engine.loaded, isEmpty, reason: 'nothing started after a pause');
    });

    test('headphones pulled while the choice is saved hold', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();
      final Completer<void> saved = Completer<void>();
      final Future<void> moving =
          controller.skipPastFailedTrack(a, after: saved.future);

      controller.onBecomingNoisyForTesting();
      // The save landing publishes "on", which the app hands to playback.
      controller.setAutomaticSkipEnabled(true);
      saved.complete();
      await moving;
      await _settle();

      expect(controller.state.currentTrack, a);
      expect(engine.loaded, isEmpty,
          reason: 'nothing may start through the speaker');
    });

    test('a cast taking over while the choice is saved holds', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();
      final Completer<void> saved = Completer<void>();
      final Future<void> moving =
          controller.skipPastFailedTrack(a, after: saved.future);

      await controller.suspend();
      // The save landing publishes "on", which the app hands to playback.
      controller.setAutomaticSkipEnabled(true);
      saved.complete();
      await moving;
      await _settle();

      expect(controller.state.currentTrack, a,
          reason: 'the receiver owns playback now');
    });

    test('Stay on a countdown while the choice is saved holds', () async {
      // A failure held at startup gets its countdown once the saved choice
      // reads on, while an Allow from the question is still being saved.
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: resolver,
        automaticRecovery: _policy,
      );
      addTearDown(controller.dispose);
      await failA(controller);
      await _pastCountdown();
      final Completer<void> saved = Completer<void>();
      final Future<void> moving =
          controller.skipPastFailedTrack(a, after: saved.future);
      controller.setAutomaticSkipEnabled(true);
      expect(controller.state.autoSkip, isNotNull);

      await controller.cancelAutomaticSkip();
      saved.complete();
      await moving;
      await _pastCountdown();

      expect(controller.state.currentTrack, a,
          reason: 'Stay on this track is the listener\'s last word');
      expect(engine.loaded, isEmpty);
    });

    test('a newer Not now while the Allow save runs is the last word',
        () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();
      final Completer<void> saved = Completer<void>();
      final Future<void> moving =
          controller.skipPastFailedTrack(a, after: saved.future);

      // Not now, from a reopened question, publishes off at once; the older
      // Allow save then lands without turning it back on.
      controller.setAutomaticSkipEnabled(false);
      saved.complete();
      await moving;
      await _settle();

      expect(controller.state.currentTrack, a);
      expect(engine.loaded, isEmpty);
    });

    test('does nothing once playback has moved on without it', () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      await failA(controller);
      await _pastCountdown();
      // A Next from a headset lands while the choice is being saved.
      await controller.skipToNext();
      await _settle();
      expect(controller.state.currentTrack, b);

      controller.setAutomaticSkipEnabled(true);
      await controller.skipPastFailedTrack(a);
      await _settle();

      expect(controller.state.currentTrack, b,
          reason: 'b is playing fine and nobody gave up on it');
      expect(engine.loaded, <String>[_url(b)]);
    });
  });

  group('driving: the media session and car controls', () {
    test('the session stays active through the countdown and follows the move',
        () async {
      final JustAudioPlaybackController controller = build();
      final LinthraAudioHandler handler = handlerFor(controller);
      await failA(controller);
      await _settle();

      final audio.PlaybackState during = handler.playbackState.value;
      expect(during.playing, isTrue,
          reason: 'the foreground service must outlive the countdown with '
              'the screen off, or the skip never happens');
      expect(during.processingState, isNot(audio.AudioProcessingState.error));

      await _pastCountdown();
      expect(handler.mediaItem.value?.id, b.id);
    });

    test('Next and Previous from the car during the countdown land once',
        () async {
      final JustAudioPlaybackController controller = build();
      final LinthraAudioHandler handler = handlerFor(controller);
      resolver.down.add(b.uri);
      await controller.playTracks(<Track>[a, b, c]);
      await _settle();
      // b fails, retries, and counts down.
      await handler.skipToNext();
      await _settle();
      expect(controller.state.autoSkip, isNotNull);

      await handler.skipToPrevious();
      await handler.skipToNext();
      await handler.skipToNext();
      await _pastCountdown();

      expect(controller.state.currentTrack, c,
          reason: 'the steering wheel decides, not the countdown');
      expect(engine.loaded.last, _url(c));
      expect(engine.loaded.where((String u) => u == _url(c)).length, 1);
    });

    test('with automatic skip off the session says it stopped, and Next works',
        () async {
      final JustAudioPlaybackController controller = build(autoSkip: false);
      final LinthraAudioHandler handler = handlerFor(controller);
      await failA(controller);
      await _pastCountdown();

      final audio.PlaybackState stopped = handler.playbackState.value;
      expect(stopped.playing, isFalse);
      expect(stopped.processingState, audio.AudioProcessingState.error);

      await handler.skipToNext();
      await _settle();
      expect(controller.state.currentTrack, b);
    });
  });
}
