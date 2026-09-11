// What happens when the file that is playing is deleted or unplugged out from
// under the player (#410).
//
// The promise is narrow and important: playback fails or skips *cleanly*. The
// queue keeps its shape, the track stays where it was, and the next skip works
// exactly as it always did, because the alternative (a half-torn-down queue,
// or a silent stop with no explanation) is how a listening session gets lost.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';

import '../../support/fake_local_file_presence.dart';

/// A fake engine that opens anything it is handed, so a failure in these tests
/// can only have come from the resolver refusing a missing file.
class _FakePlayer extends Fake implements AudioPlayer {
  final List<String> setUrlCalls = <String>[];

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
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {}
}

Track _local(String path) => Track(
      id: path,
      uri: path,
      title: path.split('/').last,
      artistName: 'Bon Iver',
      albumName: 'Bon Iver',
      duration: const Duration(minutes: 3),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Track first = _local('/music/1.flac');
  final Track second = _local('/music/2.flac');
  final Track third = _local('/music/3.flac');

  late FakeLocalFilePresence presence;
  late _FakePlayer player;
  late JustAudioPlaybackController controller;

  setUp(() {
    presence = FakeLocalFilePresence.all();
    player = _FakePlayer();
    controller = JustAudioPlaybackController(
      player: player,
      resolver: LocalPlayableUriResolver(presence: presence),
    );
    addTearDown(controller.dispose);
  });

  group('a local file that vanished mid-queue', () {
    test('the queue is left exactly as it was', () async {
      await controller.playTracks(
        <Track>[first, second, third],
        startIndex: 0,
      );
      expect(controller.state.status, isNot(PlaybackStatus.error));

      // The album folder is deleted while the first track plays.
      presence.present = <String>{};
      await controller.skipToNext();

      final PlaybackState state = controller.state;
      expect(state.status, PlaybackStatus.error);
      expect(
        state.currentTrack?.uri,
        second.uri,
        reason: 'the failed track stays where it is, rather than being dropped',
      );
      expect(
        state.upNext.map((Track t) => t.uri),
        <String>[third.uri],
        reason: 'up-next is untouched by a track that could not start',
      );
      expect(state.hasPrevious, isTrue);
    });

    test('skipping past it works normally once files are back', () async {
      await controller.playTracks(<Track>[first, second, third]);
      presence.present = <String>{first.uri, third.uri};

      await controller.skipToNext(); // 2 is gone: error, queue intact
      expect(controller.state.status, PlaybackStatus.error);

      await controller.skipToNext(); // 3 is fine: playback resumes
      expect(controller.state.currentTrack?.uri, third.uri);
      expect(controller.state.status, isNot(PlaybackStatus.error));
    });

    test('the user is told the file moved, not that a stream failed', () async {
      presence.present = <String>{};

      await controller.playTracks(<Track>[first]);

      expect(controller.state.status, PlaybackStatus.error);
      expect(controller.state.errorMessage, contains('moved or deleted'));
    });

    test('a vanished file never reaches the engine', () async {
      presence.present = <String>{};

      await controller.playTracks(<Track>[first]);

      expect(
        player.setUrlCalls,
        isEmpty,
        reason: 'refusing before the engine is what keeps the queue clean',
      );
    });

    test('nothing on disk is touched when a file goes missing', () async {
      // The whole point of failing here rather than "cleaning up": Linthra
      // never deletes or moves the user's audio. The resolver only ever asks
      // whether a path exists.
      presence.present = <String>{};

      await controller.playTracks(<Track>[first]);

      expect(presence.probed, <String>[first.uri]);
    });
  });
}
