import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/smart_precache_service.dart';
import 'package:linthra/core/services/track_prefetcher.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';

/// Records the ids it was asked to warm, in order. (The real prefetcher dedups
/// and bounds; here we only assert *what* the service decides to pre-cache.)
///
/// It records the attempt and returns without "caching" anything, which — from
/// the service's vantage point — is indistinguishable from a *failed* pre-cache:
/// the real prefetcher swallows fetch errors and returns having cached nothing.
/// So asserting on [prefetched] also proves the service doesn't re-attempt a
/// track that never succeeds.
class _RecordingPrefetcher implements TrackPrefetcher {
  final List<String> prefetched = <String>[];

  @override
  Future<void> prefetch(Track track) async {
    prefetched.add(track.id);
  }
}

/// A prefetcher whose calls block on [gate] until a test opens it, so a test can
/// hold a pre-cache "in progress" and assert the service keeps accepting new
/// playback states meanwhile — i.e. pre-cache runs off the playback path and
/// never blocks it.
class _GatedPrefetcher implements TrackPrefetcher {
  final List<String> started = <String>[];
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> prefetch(Track track) async {
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

/// Drains the microtask chain the listener + prefetch awaits run on.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('SmartPrecacheService', () {
    late StreamController<PlaybackState> states;
    late _RecordingPrefetcher prefetcher;
    late InMemoryDownloadPreferences preferences;

    setUp(() {
      states = StreamController<PlaybackState>.broadcast();
      prefetcher = _RecordingPrefetcher();
      preferences = InMemoryDownloadPreferences();
    });

    SmartPrecacheService build() => SmartPrecacheService(
          playbackStates: states.stream,
          prefetcher: prefetcher,
          preferences: preferences,
        );

    test('disabled smart pre-cache does nothing', () async {
      preferences = InMemoryDownloadPreferences(preloadEnabled: false);
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      await _settle();

      expect(prefetcher.prefetched, isEmpty);
      await service.dispose();
    });

    test('enabled pre-caches the next N tracks from the count preference',
        () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 3);
      final service = build();

      states.add(
        _playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d'), _t('e')]),
      );
      await _settle();

      // The first three upcoming tracks, in queue order — never the whole list.
      expect(prefetcher.prefetched, <String>['b', 'c', 'd']);
      await service.dispose();
    });

    test('honours a smaller upcoming-tracks count', () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 1);
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      await _settle();

      expect(prefetcher.prefetched, <String>['b']);
      await service.dispose();
    });

    test('honours a large configured count beyond the old 10 ceiling',
        () async {
      // The pre-cache loop reads the configured count — there is no hardcoded
      // 10 — so a user choosing 20 warms 20 upcoming tracks, not 10.
      preferences = InMemoryDownloadPreferences(precacheCount: 20);
      final service = build();

      final upNext = <Track>[for (int i = 0; i < 30; i++) _t('t$i')];
      states.add(_playing(_t('cur'), upNext));
      await _settle();

      expect(
        prefetcher.prefetched,
        <String>[for (int i = 0; i < 20; i++) 't$i'],
      );
      await service.dispose();
    });

    test('shuffle uses the shuffled upcoming order', () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 3);
      final service = build();

      // upNext is already the effective (shuffled) play order, so pre-caching
      // its head pre-caches the shuffled-next songs, not the catalog order.
      states.add(
        _playing(
          _t('a'),
          <Track>[_t('d'), _t('b'), _t('c'), _t('e'), _t('f')],
          shuffle: true,
        ),
      );
      await _settle();

      expect(prefetcher.prefetched, <String>['d', 'b', 'c']);
      await service.dispose();
    });

    test('repeat-one does not pre-cache aggressively (caches nothing extra)',
        () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 3);
      final service = build();

      states.add(
        _playing(
          _t('a'),
          <Track>[_t('b'), _t('c'), _t('d')],
          repeat: RepeatMode.one,
        ),
      );
      await _settle();

      expect(prefetcher.prefetched, isEmpty);
      await service.dispose();
    });

    test('repeat-all pre-caches the upcoming tracks normally', () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 3);
      final service = build();

      states.add(
        _playing(
          _t('a'),
          <Track>[_t('b'), _t('c'), _t('d'), _t('e')],
          repeat: RepeatMode.all,
        ),
      );
      await _settle();

      expect(prefetcher.prefetched, <String>['b', 'c', 'd']);
      await service.dispose();
    });

    test('reacts to a track change, not to every state update', () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 1);
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      // A position-only update keeps the same playing track and queue.
      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();

      expect(prefetcher.prefetched, <String>['b']);
      await service.dispose();
    });

    test('re-pre-caches against the new queue after advancing', () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 1);
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      await _settle();
      states.add(_playing(_t('b'), <Track>[_t('c'), _t('d')]));
      await _settle();

      expect(prefetcher.prefetched, <String>['b', 'c']);
      await service.dispose();
    });

    test('re-pre-caches the new order when shuffle toggles on', () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 1);
      final service = build();

      states.add(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      await _settle();
      // Same playing track, but shuffle reorders up-next: react to the change.
      states.add(
        _playing(_t('a'), <Track>[_t('d'), _t('c'), _t('b')], shuffle: true),
      );
      await _settle();

      expect(prefetcher.prefetched, <String>['b', 'd']);
      await service.dispose();
    });

    test('starts pre-caching once repeat-one is turned off', () async {
      preferences = InMemoryDownloadPreferences(precacheCount: 1);
      final service = build();

      states.add(
        _playing(_t('a'), <Track>[_t('b')], repeat: RepeatMode.one),
      );
      await _settle();
      expect(prefetcher.prefetched, isEmpty);

      // Same track and queue, but repeat-one cleared: now warm the next track.
      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();

      expect(prefetcher.prefetched, <String>['b']);
      await service.dispose();
    });

    test('a track that fails to cache is not retried in a tight loop',
        () async {
      // The prefetcher records each attempt and returns having cached nothing —
      // exactly how the real one behaves when a fetch fails (it swallows the
      // error). So a track that keeps "failing" stays uncached and therefore
      // remains an eligible up-next candidate.
      preferences = InMemoryDownloadPreferences(precacheCount: 1);
      final service = build();

      // Emit the same what-to-cache inputs many times, as the rapid position /
      // status ticks during playback would. The service keys off the playing
      // track, queue, shuffle and repeat — none of which changed — so it must
      // not hammer the failing track on every tick.
      for (int i = 0; i < 6; i++) {
        states.add(_playing(_t('a'), <Track>[_t('b')]));
        await _settle();
      }

      // One attempt total, despite six emissions and a persistent failure.
      expect(prefetcher.prefetched, <String>['b']);
      await service.dispose();
    });

    test('a slow pre-cache never blocks playback advancing', () async {
      // Playback (and the player feature) never await the service: it observes
      // the state stream and warms tracks as a side effect. Proven here by
      // wedging a pre-cache mid-flight and showing newer states still flow in.
      // (Playback itself resolves independently and streams an uncached track
      // immediately — see offline_first_playable_uri_resolver_test.)
      preferences = InMemoryDownloadPreferences(precacheCount: 1);
      final gated = _GatedPrefetcher();
      final service = SmartPrecacheService(
        playbackStates: states.stream,
        prefetcher: gated,
        preferences: preferences,
      );

      // Start playing 'a'; the service begins warming 'b' and that fetch blocks.
      states.add(_playing(_t('a'), <Track>[_t('b')]));
      await _settle();
      expect(gated.started, <String>['b']);

      // Playback advances to 'b' while 'b''s pre-cache is still in flight.
      // Delivering the new state must not deadlock on the stuck pre-cache.
      states.add(_playing(_t('b'), <Track>[_t('c')]));
      await _settle();
      // Still one warm at a time, so 'c' hasn't started — but nothing hung.
      expect(gated.started, <String>['b']);

      // Once the in-flight pre-cache finishes, the service catches up to the
      // latest queue and warms 'c'.
      gated.gate.complete();
      await _settle();
      expect(gated.started, <String>['b', 'c']);

      await service.dispose();
    });

    test('does nothing with an empty up-next list', () async {
      final service = build();

      states.add(_playing(_t('a'), const <Track>[]));
      await _settle();

      expect(prefetcher.prefetched, isEmpty);
      await service.dispose();
    });
  });
}
