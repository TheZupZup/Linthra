import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// An engine whose loaded source can fail while it is paused, the way the
/// real ones report it:
///
///  * Android (third_party/just_audio `AudioPlayer.java`): ExoPlayer goes on
///    buffering ahead while paused, and a load that fails then (the network
///    cut while the phone dozes, a stream URL whose token expired) reaches
///    `onPlayerError`, which sends the error on the event channel and changes
///    nothing just_audio reports as its state. The failed player stays failed:
///    `play()` only sets `playWhenReady`, so nothing is heard until another
///    source is opened.
///  * Linux (vendored just_audio_media_kit): libmpv losing the source is
///    reported only as an idle engine.
class _Engine extends Fake implements AudioPlayer {
  _Engine({required this.reportsLossAsIdle});

  final bool reportsLossAsIdle;

  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  final List<String> opened = <String>[];
  final List<Duration> seeks = <Duration>[];
  bool _playing = false;
  bool _failed = false;
  ProcessingState _processing = ProcessingState.idle;

  /// Whether anything can be heard: playing, with a source that hasn't
  /// failed.
  bool get sounding =>
      _playing && !_failed && _processing == ProcessingState.ready;

  void _report() => _states.add(PlayerState(_playing, _processing));

  /// The loaded source fails while the engine is paused.
  void loseSource() {
    _failed = true;
    if (reportsLossAsIdle) {
      _processing = ProcessingState.idle;
      _report();
    } else {
      _events.addError(PlayerException(0, 'Source error'));
    }
  }

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
    opened.add(url);
    _failed = false;
    _processing = ProcessingState.loading;
    _report();
    _processing = ProcessingState.ready;
    _report();
    await Future<void>.delayed(Duration.zero);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    _report();
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _playing = false;
    _report();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) seeks.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await _states.close();
    await _events.close();
  }
}

class _Resolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async => ResolvedPlayable(
        Uri.parse('https://host/stream/${track.id}'),
        PlaybackSource.streamingDirect,
      );
}

const Track _song = Track(
  id: 'a',
  title: 'a',
  uri: 'jellyfin:a',
  duration: Duration(minutes: 3),
);

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final bool linux in <bool>[false, true]) {
    final String platform = linux ? 'Linux' : 'Android';

    test(
        '$platform: Play after the stream failed while paused opens the song '
        'again where it was paused', () async {
      final _Engine engine = _Engine(reportsLossAsIdle: linux);
      final JustAudioPlaybackController controller = linux
          ? LinuxPlaybackController(player: engine, resolver: _Resolver())
          : JustAudioPlaybackController(player: engine, resolver: _Resolver());
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[_song]);
      await _settle();
      expect(engine.sounding, isTrue);
      controller.setPositionForTesting(const Duration(seconds: 70));

      // The listener pauses; while the phone lies there, the source the
      // engine holds fails.
      await controller.pause();
      await _settle();
      expect(controller.state.status, PlaybackStatus.paused);
      engine.loseSource();
      await _settle();

      await controller.play();
      await _settle();

      expect(engine.opened, hasLength(2),
          reason: 'the source that failed can never play again');
      expect(engine.seeks.last, const Duration(seconds: 70),
          reason: 'it picks up where the listener paused it');
      expect(engine.sounding, isTrue,
          reason: 'not "playing" over a failed source, in silence');
      expect(controller.state.status, PlaybackStatus.playing);
    });

    test(
        '$platform: a seek after the stream failed while paused is where '
        'Play opens it', () async {
      final _Engine engine = _Engine(reportsLossAsIdle: linux);
      final JustAudioPlaybackController controller = linux
          ? LinuxPlaybackController(player: engine, resolver: _Resolver())
          : JustAudioPlaybackController(player: engine, resolver: _Resolver());
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[_song]);
      await _settle();
      controller.setPositionForTesting(const Duration(seconds: 70));
      await controller.pause();
      await _settle();
      engine.loseSource();
      await _settle();

      await controller.seek(const Duration(seconds: 20));
      expect(controller.state.position, const Duration(seconds: 20));
      await controller.play();
      await _settle();

      expect(engine.opened, hasLength(2));
      expect(engine.seeks.last, const Duration(seconds: 20));
      expect(engine.sounding, isTrue);
    });
  }
}
