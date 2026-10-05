import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// An engine that opens whatever it is handed and records what it was told.
class _Engine extends Fake implements AudioPlayer {
  final List<String> loaded = <String>[];
  int stops = 0;

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
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

/// Resolves every track to a file named after it; [gate] holds one back.
class _Resolver implements PlayableUriResolver {
  final List<String> resolved = <String>[];
  final Map<String, Completer<void>> gate = <String, Completer<void>>{};

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    resolved.add(track.uri);
    await gate[track.uri]?.future;
    return ResolvedPlayable(Uri.parse(_url(track)), PlaybackSource.localFile);
  }
}

String _url(Track track) => 'file:///music/${track.id}';

Track _local(String id) => Track(id: id, title: id, uri: '/music/$id');

Track _sub(String id) => Track(id: id, title: 'Sub $id', uri: 'subsonic:$id');

bool _isSubsonic(Track track) => track.uri.startsWith('subsonic:');

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<String> _uris(Iterable<Track> tracks) =>
    <String>[for (final Track t in tracks) t.uri];

/// The queue loses a provider's songs when they stop being the signed-in
/// account's (#767): none of them may be asked of the new account's server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Engine engine;
  late _Resolver resolver;

  JustAudioPlaybackController build() {
    final JustAudioPlaybackController controller = JustAudioPlaybackController(
      player: engine,
      resolver: resolver,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    engine = _Engine();
    resolver = _Resolver();
  });

  test('songs around the current one go, and it plays on untouched', () async {
    final JustAudioPlaybackController controller = build();
    final Track a = _local('a');
    await controller.playTracks(
      <Track>[_sub('1'), a, _sub('2'), _local('b')],
      startIndex: 1,
    );
    await _settle();
    final int stopsBefore = engine.stops;

    await controller.removeTracksWhere(_isSubsonic);

    expect(controller.state.currentTrack!.uri, a.uri);
    expect(controller.state.previous, isEmpty);
    expect(controller.state.hasPrevious, isFalse);
    expect(_uris(controller.state.upNext), <String>['/music/b']);
    // No reload and no stop: only what comes before and after changed.
    expect(engine.loaded, <String>[_url(a)]);
    expect(engine.stops, stopsBefore);
  });

  test(
      'the current one going stops it and lands, stopped, on the next one '
      'left, which Play loads', () async {
    final JustAudioPlaybackController controller = build();
    final Track b = _local('b');
    await controller.playTracks(
      <Track>[_local('a'), _sub('1'), _sub('2'), b],
      startIndex: 1,
    );
    await _settle();
    final int stopsBefore = engine.stops;

    await controller.removeTracksWhere(_isSubsonic);

    expect(engine.stops, stopsBefore + 1);
    expect(controller.state.status, PlaybackStatus.idle);
    expect(controller.state.currentTrack!.uri, b.uri);
    expect(_uris(controller.state.previous), <String>['/music/a']);
    expect(controller.state.upNext, isEmpty);

    resolver.resolved.clear();
    await controller.play();
    await _settle();
    expect(resolver.resolved, <String>[b.uri]);
    expect(engine.loaded.last, _url(b));
  });

  test('with nothing left, the player is idle with an empty queue', () async {
    final JustAudioPlaybackController controller = build();
    await controller.playTracks(<Track>[_sub('1'), _sub('2')]);
    await _settle();

    await controller.removeTracksWhere(_isSubsonic);

    expect(controller.state.status, PlaybackStatus.idle);
    expect(controller.state.currentTrack, isNull);
    expect(controller.state.upNext, isEmpty);
    expect(controller.state.previous, isEmpty);
  });

  test('a song still resolving when it goes never reaches the engine',
      () async {
    final JustAudioPlaybackController controller = build();
    final Track s = _sub('1');
    final Completer<void> slowServer = Completer<void>();
    resolver.gate[s.uri] = slowServer;
    unawaited(controller.playTracks(<Track>[s, _local('b')]));
    await _settle();
    expect(resolver.resolved, <String>[s.uri]);

    await controller.removeTracksWhere(_isSubsonic);
    slowServer.complete();
    await _settle();

    expect(engine.loaded, isNot(contains(_url(s))));
    expect(controller.state.currentTrack!.uri, '/music/b');
    expect(controller.state.status, PlaybackStatus.idle);
  });

  test('nothing picked changes nothing', () async {
    final JustAudioPlaybackController controller = build();
    await controller.playTracks(<Track>[_local('a'), _local('b')]);
    await _settle();
    final PlaybackState before = controller.state;
    final int stopsBefore = engine.stops;

    await controller.removeTracksWhere(_isSubsonic);

    expect(controller.state, same(before));
    expect(engine.stops, stopsBefore);
  });
}
