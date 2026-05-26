import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/fake_playback_controller.dart';

Track _track(String id) {
  return Track(
    id: id,
    title: 'Song $id',
    uri: '/$id.mp3',
    artistName: 'Artist $id',
    albumName: 'Album $id',
  );
}

final List<Track> _library = <Track>[_track('a'), _track('b'), _track('c')];

/// Lets the broadcast from the controller's stream reach the handler's
/// listener before assertions read the mirrored session state.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('LinthraAudioHandler', () {
    late FakePlaybackController controller;
    late LinthraAudioHandler handler;

    setUp(() {
      controller = FakePlaybackController();
      final library = FakeMusicLibraryRepository(tracks: _library);
      handler = LinthraAudioHandler(controller, MediaBrowserTree(library));
    });

    tearDown(() async {
      await handler.dispose();
      await controller.dispose();
    });

    test('forwards transport commands to the controller', () async {
      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.stop();
      await handler.seek(const Duration(seconds: 12));

      expect(controller.playCount, 1);
      expect(controller.pauseCount, 1);
      expect(controller.skipCount, 1);
      expect(controller.previousCount, 1);
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

    test('exposes skipToPrevious only once a previous track exists', () async {
      await controller.playTracks([_track('a'), _track('b')]);
      await _settle();
      expect(
        handler.playbackState.value.controls,
        isNot(contains(audio.MediaControl.skipToPrevious)),
      );

      await controller.skipToNext();
      await _settle();
      expect(
        handler.playbackState.value.controls,
        contains(audio.MediaControl.skipToPrevious),
      );
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

    group('session updates are not flooded by position ticks', () {
      test('the media item is pushed once per track, not per position tick',
          () async {
        final List<audio.MediaItem?> items = <audio.MediaItem?>[];
        final sub = handler.mediaItem.listen(items.add);
        addTearDown(sub.cancel);

        await controller.playTracks(<Track>[_track('a'), _track('b')]);
        await _settle();
        // Four position-only updates for the same track, each well under a
        // second apart — exactly what the engine's position stream produces.
        for (int ms = 200; ms <= 800; ms += 200) {
          controller.emit(
            controller.state.copyWith(position: Duration(milliseconds: ms)),
          );
          await _settle();
        }

        // Only one real item (track 'a') reached the session despite the ticks.
        final List<audio.MediaItem> nonNull =
            items.whereType<audio.MediaItem>().toList();
        expect(nonNull, hasLength(1));
        expect(nonNull.single.id, 'a');
      });

      test('playback state is not re-pushed on sub-second position ticks',
          () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        final List<audio.PlaybackState> pushed = <audio.PlaybackState>[];
        final sub = handler.playbackState.listen(pushed.add);
        addTearDown(sub.cancel);
        await _settle();
        // Listening replays the current value; count only pushes after that.
        final int baseline = pushed.length;

        for (int ms = 100; ms <= 900; ms += 200) {
          controller.emit(
            controller.state.copyWith(position: Duration(milliseconds: ms)),
          );
          await _settle();
        }

        // Same shape, drift under the 1s threshold: nothing new was pushed —
        // audio_service interpolates the displayed position between pushes.
        expect(pushed.length, baseline);
      });

      test('a position jump (a seek) is pushed immediately', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        final List<audio.PlaybackState> pushed = <audio.PlaybackState>[];
        final sub = handler.playbackState.listen(pushed.add);
        addTearDown(sub.cancel);
        await _settle();
        final int baseline = pushed.length;

        // A discontinuity (>1s) is a seek/track reset and must re-sync.
        controller.emit(
          controller.state.copyWith(position: const Duration(seconds: 30)),
        );
        await _settle();

        expect(pushed.length, greaterThan(baseline));
      });

      test('a pause is pushed even when the position is steady', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        final List<audio.PlaybackState> pushed = <audio.PlaybackState>[];
        final sub = handler.playbackState.listen(pushed.add);
        addTearDown(sub.cancel);
        await _settle();
        final int baseline = pushed.length;

        // Same position, different shape (paused): a control change always pushes.
        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.paused),
        );
        await _settle();

        expect(pushed.length, greaterThan(baseline));
        expect(pushed.last.playing, isFalse);
      });
    });

    group('foreground service stays alive across buffering & transitions', () {
      // The screen-off bug: if the session reported `playing: false` during a
      // mid-stream re-buffer or a track transition, audio_service would demote
      // the foreground service and the OS could freeze the backgrounded process,
      // silencing playback until the app is reopened. So the session must stay
      // `playing` whenever the engine is working toward sound.

      test('a mid-stream re-buffer stays playing (service not demoted)',
          () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.buffering),
        );
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isTrue);
        expect(state.processingState, audio.AudioProcessingState.buffering);
        // The toggle still offers pause (not play) while buffering.
        expect(state.controls, contains(audio.MediaControl.pause));
        expect(state.controls, isNot(contains(audio.MediaControl.play)));
      });

      test('a loading track transition stays playing', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.loading),
        );
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isTrue);
        expect(state.processingState, audio.AudioProcessingState.loading);
      });

      test('a real user pause reports not-playing', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.paused),
        );
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isFalse);
        expect(state.controls, contains(audio.MediaControl.play));
        expect(state.controls, isNot(contains(audio.MediaControl.pause)));
      });

      test('completion and error report not-playing', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.completed),
        );
        await _settle();
        expect(handler.playbackState.value.playing, isFalse);
        expect(
          handler.playbackState.value.processingState,
          audio.AudioProcessingState.completed,
        );

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.error),
        );
        await _settle();
        expect(handler.playbackState.value.playing, isFalse);
      });
    });

    group('media browser', () {
      test('root lists Library and Queue as browsable categories', () async {
        final children = await handler.getChildren(MediaId.root);

        expect(children.map((i) => i.id), [MediaId.library, MediaId.queue]);
        expect(children.every((i) => i.playable == false), isTrue);
      });

      test('library lists every catalog track as a playable leaf', () async {
        final children = await handler.getChildren(MediaId.library);

        expect(children.map((i) => i.id), [
          MediaId.libraryTrack('a'),
          MediaId.libraryTrack('b'),
          MediaId.libraryTrack('c'),
        ]);
        expect(children.first.title, 'Song a');
        expect(children.first.playable, isTrue);
      });

      test('queue reflects the controller current track and up-next', () async {
        await controller.playTracks(_library, startIndex: 1);
        await _settle();

        final children = await handler.getChildren(MediaId.queue);

        // current (b) followed by up-next (c).
        expect(children.map((i) => i.title), ['Song b', 'Song c']);
        expect(children.map((i) => i.id), [
          MediaId.queueItem(0),
          MediaId.queueItem(1),
        ]);
      });

      test('selecting a library track plays it and queues the rest', () async {
        await handler.playFromMediaId(MediaId.libraryTrack('b'));
        await _settle();

        expect(controller.state.currentTrack?.id, 'b');
        expect(controller.state.upNext.map((t) => t.id), ['c']);
      });

      test('selecting a queue item plays from that position', () async {
        await controller.playTracks(_library);
        await _settle();

        await handler.playFromMediaId(MediaId.queueItem(2));
        await _settle();

        expect(controller.state.currentTrack?.id, 'c');
        expect(controller.state.hasNext, isFalse);
      });

      test('an unknown media id is a no-op', () async {
        await handler.playFromMediaId('library/missing');
        await handler.playFromMediaId('bogus');
        await _settle();

        expect(controller.playedTracks, isEmpty);
      });
    });

    group('shuffle & repeat', () {
      test('forwards setShuffleMode to the controller', () async {
        await handler.setShuffleMode(audio.AudioServiceShuffleMode.all);
        expect(controller.state.shuffleEnabled, isTrue);

        await handler.setShuffleMode(audio.AudioServiceShuffleMode.none);
        expect(controller.state.shuffleEnabled, isFalse);
      });

      test('forwards setRepeatMode to the controller', () async {
        await handler.setRepeatMode(audio.AudioServiceRepeatMode.all);
        expect(controller.state.repeatMode, RepeatMode.all);

        await handler.setRepeatMode(audio.AudioServiceRepeatMode.one);
        expect(controller.state.repeatMode, RepeatMode.one);

        await handler.setRepeatMode(audio.AudioServiceRepeatMode.none);
        expect(controller.state.repeatMode, RepeatMode.off);
      });

      test('mirrors the controller shuffle/repeat into the session', () async {
        await controller.playTracks([_track('a'), _track('b')]);
        controller.setShuffleEnabled(true);
        controller.setRepeatMode(RepeatMode.one);
        await _settle();

        final state = handler.playbackState.value;
        expect(state.shuffleMode, audio.AudioServiceShuffleMode.all);
        expect(state.repeatMode, audio.AudioServiceRepeatMode.one);
        expect(
          state.systemActions,
          containsAll(<audio.MediaAction>{
            audio.MediaAction.setShuffleMode,
            audio.MediaAction.setRepeatMode,
          }),
        );
      });
    });

    group('safe media items', () {
      final jellyfin = Track(
        id: 'jf-guid-123',
        title: 'Remote Song',
        uri: 'jellyfin:jf-guid-123',
        artistName: 'Remote Artist',
        albumName: 'Remote Album',
        artworkUri: Uri.parse(
          'https://music.example.com/Items/jf-guid-123/Images/Primary',
        ),
      );
      const local = Track(
        id: 'local-1',
        title: 'Local Song',
        uri: '/storage/music/local.mp3',
      );

      test('library items carry token-free ids, no extras, token-free art',
          () async {
        final libController = FakePlaybackController();
        final libHandler = LinthraAudioHandler(
          libController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: <Track>[jellyfin, local]),
          ),
        );
        addTearDown(() async {
          await libHandler.dispose();
          await libController.dispose();
        });

        final items = await libHandler.getChildren(MediaId.library);

        expect(items.map((i) => i.id), [
          MediaId.libraryTrack('jf-guid-123'),
          MediaId.libraryTrack('local-1'),
        ]);
        for (final item in items) {
          // Ids never carry a token, an auth query, a URI scheme, or a stream
          // URL — only the opaque catalog id.
          expect(item.id, isNot(contains('api_key')));
          expect(item.id, isNot(contains('token')));
          expect(item.id, isNot(contains('jellyfin:')));
          expect(item.id, isNot(contains('://')));
          // We attach no extras, so nothing can leak through them.
          expect(item.extras, isNull);
          // The artwork URL (when present) is the token-free image endpoint.
          final String art = item.artUri?.toString() ?? '';
          expect(art, isNot(contains('api_key')));
          expect(art.toLowerCase(), isNot(contains('token')));
        }
      });
    });
  });
}
