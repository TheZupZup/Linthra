import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/stream_preload_service.dart';
import 'package:linthra/core/services/stream_preloader.dart';

/// Records the track ids it was asked to warm, in order. Returning without
/// "caching" anything is — from the service's vantage point — indistinguishable
/// from a best-effort warm that resolved nothing, exactly like the real one.
class _RecordingPreloader implements StreamPreloader {
  final List<String> preloaded = <String>[];

  @override
  Future<void> preload(Track track) async {
    preloaded.add(track.id);
  }
}

/// A preloader whose calls block on [gate] until a test opens it, to prove a
/// slow warm runs off the playback path and never blocks new states.
class _GatedPreloader implements StreamPreloader {
  final List<String> started = <String>[];
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> preload(Track track) async {
    started.add(track.id);
    await gate.future;
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
  group('StreamPreloadService', () {
    late StreamController<PlaybackState> states;
    late _RecordingPreloader preloader;

    setUp(() {
      states = StreamController<PlaybackState>.broadcast();
      preloader = _RecordingPreloader();
    });

    StreamPreloadService build() => StreamPreloadService(
          playbackStates: states.stream,
          preloader: preloader,
        );

    test('preloads the immediate next track in queue order (shuffle off)',
        () async {
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      await _settle();

      // Only the immediate next — never the current track, never the whole queue.
      expect(preloader.preloaded, <String>['b']);
      await service.dispose();
    });

    test('preloads the shuffled-next track when shuffle is on', () async {
      final service = build();

      // upNext is already the effective (shuffled) play order, so its head is
      // the shuffled-next song.
      states.add(
        _playing(_t('a'), <Track>[_t('d'), _t('b'), _t('c')], shuffle: true),
      );
      await _settle();

      expect(preloader.preloaded, <String>['d']);
      await service.dispose();
    });

    test('repeat-one preloads nothing (no unrelated tracks)', () async {
      final service = build();

      states.add(
        _playing(_t('a'), <Track>[_t('b'), _t('c')], repeat: RepeatMode.one),
      );
      await _settle();

      expect(preloader.preloaded, isEmpty);
      await service.dispose();
    });

    test('starts preloading once repeat-one is turned off', () async {
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b')], repeat: RepeatMode.one));
      await _settle();
      expect(preloader.preloaded, isEmpty);

      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      expect(preloader.preloaded, <String>['b']);

      await service.dispose();
    });

    test('reacts to a next-track change, not to every state update', () async {
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      // A position-only update keeps the same current track and next track.
      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();

      expect(preloader.preloaded, <String>['b']);
      await service.dispose();
    });

    test('re-preloads against the new next track after advancing', () async {
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      await _settle();
      states.add(_playing(_t('b'), <Track>[_t('c'), _t('d')]));
      await _settle();

      expect(preloader.preloaded, <String>['b', 'c']);
      await service.dispose();
    });

    test('re-preloads the new head when shuffle reorders up-next', () async {
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      await _settle();
      states.add(
        _playing(_t('a'), <Track>[_t('d'), _t('c'), _t('b')], shuffle: true),
      );
      await _settle();

      expect(preloader.preloaded, <String>['b', 'd']);
      await service.dispose();
    });

    test('does nothing with an empty up-next list', () async {
      final service = build();

      states.add(_playing(_t('a'), const <Track>[]));
      await _settle();

      expect(preloader.preloaded, isEmpty);
      await service.dispose();
    });

    test('a slow preload never blocks new states arriving', () async {
      final gated = _GatedPreloader();
      final service = StreamPreloadService(
        playbackStates: states.stream,
        preloader: gated,
      );

      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      expect(gated.started, <String>['b']);

      // Advance while 'b''s warm is still in flight — must not deadlock.
      states.add(_playing(_t('b'), <Track>[_t('c')]));
      await _settle();
      expect(gated.started, <String>['b']); // still one at a time, nothing hung

      gated.gate.complete();
      await _settle();
      expect(gated.started, <String>['b', 'c']); // catches up to the latest

      await service.dispose();
    });
  });
}
