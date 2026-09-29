// A measurement harness, not a regression test.
//
// It times the work that the services hanging off the playback state stream do
// for a run of *position ticks* — the ~4 Hz emissions that make up the
// overwhelming majority of what a playing session produces, and the one cost
// that runs for the whole length of a screen-off listening session. See
// docs/battery-playback-audit.md for what it was written for and the numbers it
// produced.
//
// Deliberately named `_bench.dart`, not `_test.dart`, so `flutter test` does
// not pick it up: the numbers are machine- and load-dependent and would make a
// flaky CI gate. The invariants it inspired *are* covered by real tests
// (`test/core/services/playback_lookahead_test.dart`, the "session updates are
// not flooded by position ticks" group in `linthra_audio_handler_test.dart`).
//
// Run it explicitly, and compare two revisions on the same machine:
//
//     flutter test test/benchmarks/playback_tick_cost_bench.dart
//
// Every case emits [_ticks] position-only states, which is about five minutes
// of playback. The "stream only" case is the floor: building and delivering
// those states with nothing listening. Subtract it to read a service's own
// cost.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_artwork_prewarm_service.dart';
import 'package:linthra/core/services/media_browser_tree.dart';
import 'package:linthra/core/services/smart_precache_service.dart';
import 'package:linthra/core/services/track_prefetcher.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';

import '../features/library/fake_music_library_repository.dart';
import '../features/player/fake_playback_controller.dart';

/// Warms nothing: the benchmark measures the *deciding*, not the fetching.
class _NoopPrefetcher implements TrackPrefetcher {
  @override
  Future<void> prefetch(
    Track track, {
    Iterable<Track> keep = const <Track>[],
    bool Function()? isStillWanted,
  }) async {}
}

Track _t(int i) => Track(
      id: '$i',
      title: 'Track $i',
      uri: 'jellyfin:$i',
      albumName: 'Album ${i % 500}',
      artistName: 'Artist ${i % 200}',
      duration: const Duration(minutes: 3),
      // A credential-free reference, so the artwork prewarm has real work to
      // consider rather than skipping every cover as platform-loadable.
      artworkUri: Uri.parse('subsonic-cover:$i'),
    );

/// About five minutes of playback at the ~4 Hz position flush.
const int _ticks = 1200;

/// A big-but-real library selection: "play all songs" on a large collection.
const int _queueLength = 20000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BENCH stream only (the floor)', () async {
    final List<Track> upNext = <Track>[for (int i = 0; i < 5000; i++) _t(i)];
    final StreamController<PlaybackState> states =
        StreamController<PlaybackState>.broadcast();
    states.stream.listen((_) {});
    PlaybackState state = PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _t(99999),
      upNext: upNext,
    );
    states.add(state);
    await Future<void>.delayed(Duration.zero);

    final Stopwatch sw = Stopwatch()..start();
    for (int i = 0; i < _ticks; i++) {
      state = state.copyWith(position: Duration(milliseconds: i * 250));
      states.add(state);
    }
    await Future<void>.delayed(Duration.zero);
    sw.stop();
    // ignore: avoid_print
    print('BENCH stream only, $_ticks ticks: ${sw.elapsedMicroseconds}us');
    await states.close();
  });

  test('BENCH media-session bridge', () async {
    final List<Track> queue = <Track>[
      for (int i = 0; i < _queueLength; i++) _t(i),
    ];
    final FakePlaybackController controller = FakePlaybackController();
    final LinthraAudioHandler handler = LinthraAudioHandler(
      controller,
      MediaBrowserTree(FakeMusicLibraryRepository()),
    );
    await controller.playTracks(queue, startIndex: _queueLength ~/ 2);
    await Future<void>.delayed(Duration.zero);

    final Stopwatch sw = Stopwatch()..start();
    for (int i = 0; i < _ticks; i++) {
      controller.emit(
        controller.state.copyWith(position: Duration(milliseconds: i * 250)),
      );
    }
    await Future<void>.delayed(Duration.zero);
    sw.stop();
    // ignore: avoid_print
    print('BENCH media-session bridge, $_queueLength-track queue, $_ticks '
        'ticks: ${sw.elapsedMicroseconds}us');
    await handler.dispose();
    await controller.dispose();
  });

  test('BENCH look-ahead services', () async {
    final List<Track> upNext = <Track>[for (int i = 0; i < 5000; i++) _t(i)];
    final StreamController<PlaybackState> states =
        StreamController<PlaybackState>.broadcast();
    SmartPrecacheService(
      playbackStates: states.stream,
      prefetcher: _NoopPrefetcher(),
      preferences: InMemoryDownloadPreferences(),
    );
    MediaArtworkPrewarmService(
      playbackStates: states.stream,
      warm: (Uri _) async => null,
    );

    PlaybackState state = PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _t(99999),
      upNext: upNext,
    );
    states.add(state);
    await Future<void>.delayed(Duration.zero);

    final Stopwatch sw = Stopwatch()..start();
    for (int i = 0; i < _ticks; i++) {
      state = state.copyWith(position: Duration(milliseconds: i * 250));
      states.add(state);
    }
    await Future<void>.delayed(Duration.zero);
    sw.stop();
    // ignore: avoid_print
    print('BENCH look-ahead services, 5000-track up-next, $_ticks ticks: '
        '${sw.elapsedMicroseconds}us');
    await states.close();
  });

  test('BENCH session document encode (Linux crash-safe session)', () async {
    // What one debounced position save costs before it ever reaches the disk.
    final List<Track> tracks = <Track>[for (int i = 0; i < 200; i++) _t(i)];
    final PersistedPlaybackSession? session =
        PersistedPlaybackSession.fromPlayback(
      previous: tracks.sublist(0, 50),
      current: tracks[50],
      upNext: tracks.sublist(51),
      position: const Duration(seconds: 30),
      shuffleEnabled: false,
      repeatMode: RepeatMode.off,
    );
    const int rounds = 100;
    final Stopwatch sw = Stopwatch()..start();
    int bytes = 0;
    for (int i = 0; i < rounds; i++) {
      bytes = jsonEncode(session!.toJson()).length;
    }
    sw.stop();
    // ignore: avoid_print
    print('BENCH session encode, 200-track queue: ${bytes}B, '
        '${(sw.elapsedMicroseconds / rounds).toStringAsFixed(0)}us/encode');
  });
}
