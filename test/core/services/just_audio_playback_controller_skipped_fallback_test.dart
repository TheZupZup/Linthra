// A walk to another copy of a song that the listener skips away from.
//
// When a track can't go on from the copy it was playing, the controller tries
// the song's other copies (another server's), automatically after a
// mid-stream failure or when the listener taps "Try another source". Those
// copies resolve against a server that may take its time. If the listener
// presses Next meanwhile, the next track owns playback: the other copy failing
// to resolve after that is about a song they have left, and must not put an
// error (naming that song) on top of the track they are listening to, nor
// load anything.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_candidate_source.dart';
import 'package:linthra/core/services/stream_interruption.dart';

/// Records the sources the engine opens and its transport, in order.
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<String> loadedUrls = <String>[];
  final List<String> transport = <String>[];

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
    loadedUrls.add(url);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async => transport.add('play');
  @override
  Future<void> pause() async => transport.add('pause');
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

/// A resolver whose answers the test releases by hand. Uris in [immediate]
/// resolve at once.
class _GatedResolver implements PlayableUriResolver {
  _GatedResolver({required Set<String> immediate}) : _immediate = immediate;

  final Set<String> _immediate;
  final Map<String, Completer<ResolvedPlayable>> _gates =
      <String, Completer<ResolvedPlayable>>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) {
    if (_immediate.contains(track.uri)) {
      return Future<ResolvedPlayable>.value(ResolvedPlayable(
        Uri.parse(_url(track)),
        PlaybackSource.streamingDirect,
      ));
    }
    return _gates
        .putIfAbsent(track.uri, () => Completer<ResolvedPlayable>())
        .future;
  }

  bool isWaiting(String uri) =>
      _gates.containsKey(uri) && !_gates[uri]!.isCompleted;

  /// That server doesn't answer either.
  void failUnreachable(Track track) => _gates.remove(track.uri)!.completeError(
        const PlaybackResolutionException(
          "Couldn't reach your music server.",
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        ),
      );
}

Track _track(String id, {String provider = 'jellyfin'}) =>
    Track(id: id, title: id, uri: '$provider:$id');

String _url(Track track) => 'https://host/stream/${track.uri}';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track x = _track('x');
  final Track subsonicX = _track('x', provider: 'subsonic');
  final Track b = _track('b');

  /// What the listener sees on [b], the track they skipped to.
  void expectUndisturbedOnB(
    JustAudioPlaybackController controller,
    _RecordingPlayer player,
  ) {
    expect(controller.state.currentTrack?.uri, b.uri);
    expect(controller.state.status, isNot(PlaybackStatus.error),
        reason: "the copy of the song they left failed, not B");
    expect(controller.state.failure, isNull);
    expect(controller.state.playWhenReady, isTrue);
    expect(player.loadedUrls, isNot(contains(_url(subsonicX))));
    expect(player.loadedUrls.last, _url(b));
    expect(player.transport.last, 'play');
  }

  test(
      "the automatic walk to another copy failing after a skip leaves the "
      'next track alone', () async {
    final _RecordingPlayer player = _RecordingPlayer();
    final _GatedResolver resolver =
        _GatedResolver(immediate: <String>{x.uri, b.uri});
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      candidates: MapPlaybackCandidateSource(
        () => <String, List<Track>>{
          x.uri: <Track>[x, subsonicX],
        },
      ),
    )..midStreamBufferingTimeout = const Duration(hours: 1);
    addTearDown(controller.dispose);
    await controller.playTracks(<Track>[x, b]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));

    // X's session expires mid-song: no quick reconnect, straight to the walk
    // through X's other copies, whose server is slow to answer.
    controller.handleStreamFailureForTesting(const StreamInterruption(
      StreamInterruptionKind.sessionExpired,
      'Your session expired. Sign in again to keep streaming.',
      retryable: false,
    ));
    await _settle();
    expect(resolver.isWaiting(subsonicX.uri), isTrue);

    await controller.skipToNext();
    await _settle();
    expect(controller.state.currentTrack?.uri, b.uri);

    resolver.failUnreachable(subsonicX);
    await _settle();

    expectUndisturbedOnB(controller, player);
  });

  test('Try another source failing after a skip leaves the next track alone',
      () async {
    final _RecordingPlayer player = _RecordingPlayer();
    final _GatedResolver resolver = _GatedResolver(immediate: <String>{b.uri});
    final Map<String, List<Track>> copies = <String, List<Track>>{};
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: player,
      resolver: resolver,
      candidates: MapPlaybackCandidateSource(() => copies),
    );
    addTearDown(controller.dispose);

    // X fails to start; another copy of it has since become known.
    final Future<void> play = controller.playTracks(<Track>[x, b]);
    await _settle();
    resolver.failUnreachable(x);
    await play;
    expect(controller.state.status, PlaybackStatus.error);
    copies[x.uri] = <Track>[x, subsonicX];

    final Future<void> attempt = controller.tryAnotherSource();
    await _settle();
    expect(resolver.isWaiting(subsonicX.uri), isTrue);

    // The listener gives up on X while that copy is still resolving.
    await controller.skipToNext();
    await _settle();
    expect(controller.state.currentTrack?.uri, b.uri);

    resolver.failUnreachable(subsonicX);
    await attempt;
    await _settle();

    expectUndisturbedOnB(controller, player);
  });
}
