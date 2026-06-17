import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// A fake engine that records, in order, every source it was handed and every
/// play/seek it was asked to perform — so a test can prove a stale rapid-skip
/// never reaches the engine. No platform channel is touched.
class _RecordingPlayer extends Fake implements AudioPlayer {
  final List<String> setUrlCalls = <String>[];
  final List<Duration> seekCalls = <Duration>[];
  int playCalls = 0;

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
    setUrlCalls.add(url);
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
    if (position != null) seekCalls.add(position);
  }

  @override
  Future<void> dispose() async {}
}

/// A resolver whose per-track completion the test drives by hand: a uri in
/// [immediate] resolves on the next microtask; any other uri parks on a
/// [Completer] the test releases with [release], so resolution order — and thus
/// the race — is fully deterministic.
class _GatedResolver implements PlayableUriResolver {
  _GatedResolver(this.immediate);

  final Map<String, ResolvedPlayable> immediate;
  final Map<String, Completer<ResolvedPlayable>> _gates =
      <String, Completer<ResolvedPlayable>>{};
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) {
    calls.add(track.uri);
    final ResolvedPlayable? r = immediate[track.uri];
    if (r != null) return Future<ResolvedPlayable>.value(r);
    return _gates
        .putIfAbsent(track.uri, () => Completer<ResolvedPlayable>())
        .future;
  }

  void release(String uri, ResolvedPlayable resolved) =>
      _gates[uri]!.complete(resolved);

  void releaseError(String uri, Object error) =>
      _gates[uri]!.completeError(error);
}

Track _track(String id) => Track(
      id: id,
      title: id,
      uri: 'jellyfin:$id',
      duration: const Duration(minutes: 3),
    );

String _url(String id) => 'https://host/stream/$id';

ResolvedPlayable _stream(String id) =>
    ResolvedPlayable(Uri.parse(_url(id)), PlaybackSource.streamingDirect);

/// Flushes pending microtasks (and the zero-delay timer) so awaited
/// continuations run to completion.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rapid skip is race-safe (playback generation guard)', () {
    test(
        'a stale skip whose load finishes late never loads, plays, or shows '
        'its track', () async {
      final a = _track('a');
      final b = _track('b');
      final c = _track('c');
      final player = _RecordingPlayer();
      // A and C resolve immediately; B is gated so its load can finish *after*
      // the user has already skipped past it to C — the exact overlap that used
      // to leave the wrong track playing.
      final resolver = _GatedResolver(<String, ResolvedPlayable>{
        'jellyfin:a': _stream('a'),
        'jellyfin:c': _stream('c'),
      });
      final controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[a, b, c]);
      expect(controller.state.currentTrack?.id, 'a');

      // Rapid skip A → B (B parks on its gate) → C before B resolves.
      final Future<void> toB = controller.skipToNext();
      final Future<void> toC = controller.skipToNext();
      await _settle();

      // C is the track that actually reached the engine and started.
      expect(controller.state.currentTrack?.id, 'c');
      expect(player.setUrlCalls, <String>[_url('a'), _url('c')]);
      // Queue order is intact: A and B are history, nothing is up next.
      expect(controller.state.previous.map((Track t) => t.id).toList(),
          <String>['a', 'b']);
      expect(controller.state.upNext, isEmpty);

      // B's slow resolve finally lands — it must be ignored entirely.
      resolver.release('jellyfin:b', _stream('b'));
      await _settle();
      await Future.wait(<Future<void>>[toB, toC]);

      expect(controller.state.currentTrack?.id, 'c',
          reason: 'a skip that resolved late must not change the track');
      expect(player.setUrlCalls, isNot(contains(_url('b'))),
          reason: 'the engine must never be handed the superseded track');
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('a stale candidate that fails late does not surface an error',
        () async {
      // The stale load eventually *fails* (B never resolves successfully). A
      // late failure on a track the user skipped past must not show an error on
      // the track they actually landed on.
      final a = _track('a');
      final b = _track('b');
      final c = _track('c');
      final player = _RecordingPlayer();
      final resolver = _GatedResolver(<String, ResolvedPlayable>{
        'jellyfin:a': _stream('a'),
        'jellyfin:c': _stream('c'),
      });
      final controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[a, b, c]);
      final Future<void> toB = controller.skipToNext();
      final Future<void> toC = controller.skipToNext();
      await _settle();
      expect(controller.state.currentTrack?.id, 'c');

      // B's gate completes with a failure now that we've already moved on.
      resolver.releaseError(
        'jellyfin:b',
        const PlaybackResolutionException(
          'That source needs attention.',
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        ),
      );
      await _settle();
      await Future.wait(<Future<void>>[toB, toC]);

      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(controller.state.currentTrack?.id, 'c');
    });
  });

  group('normal playback flow is unchanged', () {
    test('a single skip loads and plays the next track', () async {
      final a = _track('a');
      final b = _track('b');
      final player = _RecordingPlayer();
      final resolver = _GatedResolver(<String, ResolvedPlayable>{
        'jellyfin:a': _stream('a'),
        'jellyfin:b': _stream('b'),
      });
      final controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[a, b]);
      await controller.skipToNext();

      expect(controller.state.currentTrack?.id, 'b');
      expect(controller.state.status, isNot(PlaybackStatus.error));
      expect(player.setUrlCalls, <String>[_url('a'), _url('b')]);
      expect(player.playCalls, 2);
    });

    test('seek on a playing track is forwarded to the engine', () async {
      final a = _track('a');
      final player = _RecordingPlayer();
      final resolver = _GatedResolver(<String, ResolvedPlayable>{
        'jellyfin:a': _stream('a'),
      });
      final controller =
          JustAudioPlaybackController(player: player, resolver: resolver);
      addTearDown(controller.dispose);

      await controller.playTracks(<Track>[a]);
      await controller.seek(const Duration(seconds: 30));

      expect(player.seekCalls, contains(const Duration(seconds: 30)));
      expect(controller.state.currentTrack?.id, 'a');
    });
  });
}
