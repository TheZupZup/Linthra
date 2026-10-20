import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_resolver.dart';
import 'package:linthra/core/services/remote_cache/remote_playback_cache.dart';
import 'package:linthra/core/services/remote_cache/remote_stream_prebufferer.dart';
import 'package:linthra/core/services/remote_prebuffer_service.dart';

import 'fake_stream_resolver.dart';

/// A resolver whose calls block on [gate] until a test opens it, to prove a slow
/// warm runs off the playback path and never blocks new states.
class _GatedResolver implements PlayableUriResolver {
  final List<String> started = <String>[];
  final Completer<void> gate = Completer<void>();
  int _counter = 0;

  @override
  bool handles(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    started.add(track.id);
    await gate.future;
    _counter++;
    return ResolvedPlayable(
      Uri.parse('https://server.example/${track.id}?n=$_counter'),
      PlaybackSource.streamingDirect,
    );
  }
}

Track _t(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

PlaybackState _playing(
  Track current,
  List<Track> upNext, {
  bool shuffle = false,
  RepeatMode repeat = RepeatMode.off,
}) =>
    PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: current,
      upNext: upNext,
      shuffleEnabled: shuffle,
      repeatMode: repeat,
    );

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('RemotePrebufferService', () {
    late StreamController<PlaybackState> states;
    late FakeStreamResolver inner;
    late RemotePlaybackCache cache;

    setUp(() {
      states = StreamController<PlaybackState>.broadcast();
      inner = FakeStreamResolver();
      cache = RemotePlaybackCache();
    });

    RemotePrebufferService build({int ahead = 1}) => RemotePrebufferService(
          playbackStates: states.stream,
          prebufferer: RemoteStreamPrebufferer(resolver: inner, cache: cache),
          ahead: ahead,
        );

    test('prepares the current track and the immediate next (shuffle off)',
        () async {
      final RemotePrebufferService service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      await _settle();

      // Current + exactly one ahead — never the whole queue.
      expect(inner.resolved, <String>['a', 'b']);
      await service.dispose();
    });

    test('prepares the shuffled-next track when shuffle is on', () async {
      final RemotePrebufferService service = build();

      states.add(
        _playing(_t('a'), <Track>[_t('d'), _t('b'), _t('c')], shuffle: true),
      );
      await _settle();

      expect(inner.resolved, <String>['a', 'd']);
      await service.dispose();
    });

    test('repeat-one prepares only the current track (no up-next)', () async {
      final RemotePrebufferService service = build();

      states.add(
        _playing(_t('a'), <Track>[_t('b'), _t('c')], repeat: RepeatMode.one),
      );
      await _settle();

      expect(inner.resolved, <String>['a']);
      await service.dispose();
    });

    test('starts preparing up-next once repeat-one is turned off', () async {
      final RemotePrebufferService service = build();

      states.add(_playing(_t('a'), <Track>[_t('b')], repeat: RepeatMode.one));
      await _settle();
      expect(inner.resolved, <String>['a']); // only current under repeat-one

      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      // 'a' is already warm so it is skipped; the next 'b' is warmed now.
      expect(inner.resolved, <String>['a', 'b']);

      await service.dispose();
    });

    test('reacts to a next-track change, not to every state update', () async {
      final RemotePrebufferService service = build();

      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      // A position-only update keeps the same current and next track.
      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();

      expect(inner.resolved, <String>['a', 'b']); // one pass only
      await service.dispose();
    });

    test('re-prepares against the new next track after advancing', () async {
      final RemotePrebufferService service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      await _settle();
      states.add(_playing(_t('b'), <Track>[_t('c'), _t('d')]));
      await _settle();

      // Pass 1: a, b. Pass 2: b already warm (skipped), c warmed.
      expect(inner.resolved, <String>['a', 'b', 'c']);
      await service.dispose();
    });

    test('does only the current track with an empty up-next list', () async {
      final RemotePrebufferService service = build();

      states.add(_playing(_t('a'), const <Track>[]));
      await _settle();

      expect(inner.resolved, <String>['a']);
      await service.dispose();
    });

    test('a slow warm never blocks new states arriving', () async {
      final _GatedResolver gated = _GatedResolver();
      final RemotePrebufferService service = RemotePrebufferService(
        playbackStates: states.stream,
        prebufferer: RemoteStreamPrebufferer(resolver: gated, cache: cache),
      );

      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      expect(gated.started, <String>['a']); // blocked warming the current track

      // Advance while 'a''s warm is still in flight — must not deadlock.
      states.add(_playing(_t('b'), <Track>[_t('c')]));
      await _settle();
      expect(gated.started, <String>['a']); // still one at a time, nothing hung

      gated.gate.complete();
      await _settle();
      await _settle();
      // Catches up: finishes pass 1 (a, b) then the latest pass (b warm → c).
      expect(gated.started, <String>['a', 'b', 'c']);

      await service.dispose();
    });
  });

  group('near the end of the current track', () {
    // A warmed URL is fresh for two minutes; these tracks run longer.
    const Duration length = Duration(minutes: 3, seconds: 40);
    late StreamController<PlaybackState> states;
    late FakeStreamResolver inner;
    late RemotePlaybackCache cache;
    late DateTime now;

    setUp(() {
      states = StreamController<PlaybackState>.broadcast();
      inner = FakeStreamResolver();
      cache = RemotePlaybackCache();
      now = DateTime(2026, 10, 20, 12);
    });

    RemotePrebufferService build() {
      final RemotePrebufferService service = RemotePrebufferService(
        playbackStates: states.stream,
        prebufferer: RemoteStreamPrebufferer(
          resolver: inner,
          cache: cache,
          clock: () => now,
        ),
      );
      addTearDown(service.dispose);
      return service;
    }

    PlaybackState at(
      Duration position, {
      PlaybackStatus status = PlaybackStatus.playing,
      Duration duration = length,
      List<Track>? upNext,
      List<Track> previous = const <Track>[],
      RepeatMode repeat = RepeatMode.off,
    }) =>
        PlaybackState(
          status: status,
          currentTrack: _t('a'),
          upNext: upNext ?? <Track>[_t('b'), _t('c')],
          previous: previous,
          position: position,
          duration: duration,
          repeatMode: repeat,
        );

    /// Plays on to [position], as long after the track started.
    Future<void> playTo(Duration position, {PlaybackStatus? status}) async {
      now = DateTime(2026, 10, 20, 12).add(position);
      states.add(at(position, status: status ?? PlaybackStatus.playing));
      await _settle();
    }

    test('warms the next track again once the earlier warm has gone stale',
        () async {
      build();
      states.add(at(Duration.zero));
      await _settle();
      expect(inner.resolved, <String>['a', 'b']);

      await playTo(const Duration(minutes: 2, seconds: 30));
      expect(inner.resolved, <String>['a', 'b'], reason: 'not near the end');

      await playTo(const Duration(minutes: 3, seconds: 15));
      expect(inner.resolved, <String>['a', 'b', 'b']);
    });

    test('the roll into the next track is served from that warm', () async {
      final RemoteCacheResolver player = RemoteCacheResolver(
        inner: inner,
        cache: cache,
        clock: () => now,
      );
      build();
      states.add(at(Duration.zero));
      await _settle();
      await playTo(const Duration(minutes: 3, seconds: 15));
      final int before = inner.resolved.length;

      now = now.add(const Duration(seconds: 25));
      await player.resolve(_t('b'));

      expect(inner.resolved, hasLength(before),
          reason: 'the change must not resolve the track again');
    });

    test('reaches the server only when the earlier warm is stale', () async {
      // A short track: the warm from its start is still fresh at its end.
      build();
      states.add(at(Duration.zero, duration: const Duration(minutes: 1)));
      await _settle();

      now = now.add(const Duration(seconds: 45));
      states.add(at(
        const Duration(seconds: 45),
        duration: const Duration(minutes: 1),
      ));
      await _settle();

      expect(inner.resolved, <String>['a', 'b']);
    });

    test('warms once while the track stays in its last stretch', () async {
      build();
      states.add(at(Duration.zero));
      await _settle();

      await playTo(const Duration(minutes: 3, seconds: 15));
      // A warm that failed must not turn every position tick into a request.
      inner.fail = true;
      await playTo(const Duration(minutes: 3, seconds: 16));
      await playTo(const Duration(minutes: 3, seconds: 20));
      await playTo(const Duration(minutes: 3, seconds: 30));

      expect(inner.resolved, <String>['a', 'b', 'b']);
    });

    test('warms nothing while paused there', () async {
      build();
      states.add(at(Duration.zero));
      await _settle();

      await playTo(
        const Duration(minutes: 3, seconds: 15),
        status: PlaybackStatus.paused,
      );

      expect(inner.resolved, <String>['a', 'b']);
    });

    test('a pause in the last stretch warms it again on resume if stale',
        () async {
      build();
      states.add(at(Duration.zero));
      await _settle();
      await playTo(const Duration(minutes: 3, seconds: 15));
      expect(inner.resolved, <String>['a', 'b', 'b']);

      states.add(at(
        const Duration(minutes: 3, seconds: 15),
        status: PlaybackStatus.paused,
      ));
      await _settle();
      // Paused long enough for that warm to go stale.
      now = now.add(const Duration(minutes: 5));
      states.add(at(const Duration(minutes: 3, seconds: 16)));
      await _settle();

      expect(inner.resolved, <String>['a', 'b', 'b', 'b']);
    });

    test('under repeat-all, the last track warms the first one again',
        () async {
      build();
      final PlaybackState start = at(
        Duration.zero,
        upNext: const <Track>[],
        previous: <Track>[_t('x'), _t('y')],
        repeat: RepeatMode.all,
      );
      states.add(start);
      await _settle();
      expect(inner.resolved, <String>['a']);

      now = now.add(const Duration(minutes: 3, seconds: 15));
      states.add(at(
        const Duration(minutes: 3, seconds: 15),
        upNext: const <Track>[],
        previous: <Track>[_t('x'), _t('y')],
        repeat: RepeatMode.all,
      ));
      await _settle();

      expect(inner.resolved, <String>['a', 'x']);
    });

    test('under repeat-one, nothing else is warmed', () async {
      build();
      states.add(at(Duration.zero, repeat: RepeatMode.one));
      await _settle();

      now = now.add(const Duration(minutes: 3, seconds: 15));
      states.add(at(
        const Duration(minutes: 3, seconds: 15),
        repeat: RepeatMode.one,
      ));
      await _settle();

      expect(inner.resolved, <String>['a']);
    });
  });
}
