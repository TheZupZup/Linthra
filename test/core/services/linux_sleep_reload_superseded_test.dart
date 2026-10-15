// A skip while the Linux reload after a system sleep waits to run (#799).
//
// After a wake the controller waits a moment (for the audio device and the
// network to come back) and then reloads the track that was playing, where it
// was. The listener may press Next in that moment, from a media key or the
// shell's controls. The next track is loaded then and owns playback, so the
// reload must not run afterwards: not for the track they left, and not as a
// second load of the one they skipped to.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

import '../../support/fake_machine_sleep.dart';

/// Records every source the engine opens; reports nothing itself.
class _Engine extends Fake implements AudioPlayer {
  final List<String> setUrlCalls = <String>[];
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
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

class _Resolver implements PlayableUriResolver {
  final List<String> calls = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    calls.add(track.uri);
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.id}?n=${calls.length}'),
      PlaybackSource.streamingDirect,
    );
  }
}

const Track _playing = Track(id: 'r', title: 'R', uri: 'jellyfin:r');
const Track _next = Track(id: 'n', title: 'N', uri: 'jellyfin:n');

void main() {
  testWidgets('a skip during the wait after a wake leaves the reload undone',
      (WidgetTester tester) async {
    final _Engine engine = _Engine();
    final _Resolver resolver = _Resolver();
    final FakeMachineSleep machine = FakeMachineSleep();
    final LinuxPlaybackController controller = LinuxPlaybackController(
      player: engine,
      resolver: resolver,
      sleepWatcher: machine.watcher(),
    )
      ..suspendResumeBackoff = const Duration(seconds: 2)
      ..midStreamBufferingTimeout = const Duration(hours: 1);
    addTearDown(controller.dispose);
    await controller.playTracks(<Track>[_playing, _next]);
    controller.handleEngineState(PlayerState(true, ProcessingState.ready));
    expect(machine.isWatched, isTrue);

    // The lid opens; the reload waits for the device and the network.
    machine.sleep(const Duration(minutes: 30));
    machine.look();
    await tester.pump(const Duration(seconds: 1));
    expect(engine.setUrlCalls, hasLength(1), reason: 'still waiting');

    // Next, from a media key, inside that wait.
    await controller.skipToNext();
    await tester.pump();
    expect(engine.setUrlCalls, hasLength(2));

    // Well past the wait.
    await tester.pump(const Duration(seconds: 5));

    expect(resolver.calls, <String>[_playing.uri, _next.uri],
        reason: 'neither track is resolved again by the stale reload');
    expect(engine.setUrlCalls, <String>[
      'https://server.example/stream/r?n=1',
      'https://server.example/stream/n?n=2',
    ]);
    expect(engine.playCalls, 2);
    expect(controller.state.currentTrack, _next);
  });
}
