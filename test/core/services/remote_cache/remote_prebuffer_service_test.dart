import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
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
          prebufferer:
              RemoteStreamPrebufferer(resolver: inner, cache: cache),
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
}
