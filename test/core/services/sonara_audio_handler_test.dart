import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/models/playback_state.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/core/services/sonara_audio_handler.dart';

import '../../features/player/fake_playback_controller.dart';

Track _track(String id) => Track(
      id: id,
      title: 'Song $id',
      uri: '/$id.mp3',
      artistName: 'Artist $id',
      albumName: 'Album $id',
    );

/// Lets the broadcast from the controller's stream reach the handler's
/// listener before assertions read the mirrored session state.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('SonaraAudioHandler', () {
    late FakePlaybackController controller;
    late SonaraAudioHandler handler;

    setUp(() {
      controller = FakePlaybackController();
      handler = SonaraAudioHandler(controller);
    });

    tearDown(() async {
      await handler.dispose();
      await controller.dispose();
    });

    test('forwards transport commands to the controller', () async {
      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.stop();
      await handler.seek(const Duration(seconds: 12));

      expect(controller.playCount, 1);
      expect(controller.pauseCount, 1);
      expect(controller.skipCount, 1);
      expect(controller.stopCount, 1);
      expect(controller.seeks, [const Duration(seconds: 12)]);
    });

    test('mirrors the current track into the media item', () async {
      await controller.playTracks([_track('a'), _track('b')]);
      await _settle();

      final item = handler.mediaItem.value;
      expect(item, isNotNull);
      expect(item!.id, 'a');
      expect(item.title, 'Song a');
      expect(item.artist, 'Artist a');
      expect(item.album, 'Album a');
    });

    test('queue: state is ready with pause, stop and skip controls', () async {
      await controller.playTracks([_track('a'), _track('b')]);
      await _settle();

      final state = handler.playbackState.value;
      expect(state.playing, isTrue);
      expect(state.processingState, audio.AudioProcessingState.ready);
      expect(state.controls, contains(audio.MediaControl.pause));
      expect(state.controls, contains(audio.MediaControl.stop));
      expect(state.controls, contains(audio.MediaControl.skipToNext));
    });

    test('omits the skip control when nothing is queued next', () async {
      await controller.playTracks([_track('a')]);
      await _settle();

      final state = handler.playbackState.value;
      expect(state.controls, isNot(contains(audio.MediaControl.skipToNext)));
    });

    test('clears the media item when playback goes idle', () async {
      await controller.playTracks([_track('a')]);
      await _settle();
      expect(handler.mediaItem.value, isNotNull);

      controller.emit(PlaybackState.idle);
      await _settle();

      expect(handler.mediaItem.value, isNull);
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        audio.AudioProcessingState.idle,
      );
    });
  });
}
