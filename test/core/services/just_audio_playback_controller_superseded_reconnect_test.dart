import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// An engine that reports a dropped stream the way the real ones do:
///
///  * Android (just_audio): its `playing` flag survives a failure and a load,
///    a load reports loading then ready before it answers, and a stream that
///    drops stalls and then raises an error on the event channel.
///  * Linux (vendored just_audio_media_kit): libmpv losing the source is
///    reported only as an idle engine.
///
/// A source that failed plays no more until another one is opened.
class _Engine extends Fake implements AudioPlayer {
  _Engine({required this.reportsLossAsIdle});

  final bool reportsLossAsIdle;

  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  final List<String> opened = <String>[];
  bool _playing = false;
  bool _failed = false;
  ProcessingState _processing = ProcessingState.idle;

  /// Whether anything can be heard.
  bool get sounding =>
      _playing && !_failed && _processing == ProcessingState.ready;

  void _report() => _states.add(PlayerState(_playing, _processing));

  /// The connection drops.
  void dropStream() {
    _failed = true;
    if (reportsLossAsIdle) {
      _processing = ProcessingState.idle;
      _report();
      return;
    }
    _processing = ProcessingState.buffering;
    _report();
    _events.addError(PlayerException(0, 'Source error'));
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
  Future<void> seek(Duration? position, {int? index}) async {}

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
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await _states.close();
    await _events.close();
  }
}

/// Resolves at once, except a uri the test holds: that one waits, as a
/// server that stopped answering keeps a request waiting until it times out.
class _Resolver implements PlayableUriResolver {
  final Map<String, Completer<void>> held = <String, Completer<void>>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final Completer<void>? gate = held.remove(track.uri);
    if (gate != null) await gate.future;
    return ResolvedPlayable(
      Uri.parse('https://host/stream/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

Track _track(String id) => Track(
      id: id,
      title: id,
      uri: 'jellyfin:$id',
      duration: const Duration(minutes: 3),
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
        '$platform: a reconnect the listener skipped away from, still waiting '
        'on its server, does not swallow the next song\'s own drop', () async {
      final Track a = _track('a');
      final Track b = _track('b');
      final _Engine engine = _Engine(reportsLossAsIdle: linux);
      final _Resolver resolver = _Resolver();
      final JustAudioPlaybackController controller = (linux
          ? LinuxPlaybackController(player: engine, resolver: resolver)
          : JustAudioPlaybackController(player: engine, resolver: resolver))
        ..streamRetryBackoff = Duration.zero
        ..midStreamBufferingTimeout = const Duration(hours: 1);
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[a, b]);
      await _settle();
      expect(controller.state.status, PlaybackStatus.playing);

      // A's stream drops; its quick reconnect waits on a server that has
      // stopped answering, so the listener presses Next while it says
      // Reconnecting.
      final Completer<void> aServer = resolver.held[a.uri] = Completer<void>();
      engine.dropStream();
      await _settle();
      expect(controller.state.status, PlaybackStatus.reconnecting);
      await controller.skipToNext();
      await _settle();
      expect(controller.state.currentTrack, b);
      expect(engine.sounding, isTrue, reason: 'B plays');

      // B's own stream drops while A's reconnect is still waiting.
      engine.dropStream();
      await _settle();
      // A's server finally answers (or times out); that reconnect is long
      // superseded.
      aServer.complete();
      await _settle();

      expect(engine.opened.last, 'https://host/stream/b',
          reason: 'B gets its quick reconnect');
      expect(engine.opened, hasLength(3),
          reason: 'B was opened again after its drop');
      expect(engine.sounding, isTrue,
          reason: 'not "playing" over B\'s dropped stream, in silence');
    });
  }
}
