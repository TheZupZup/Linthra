import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/fake_playback_controller.dart';
import 'fake_browse_repositories.dart';

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

      test('a car skip that loads the next track stays playing', () async {
        // A skip (from the car/notification, screen off) briefly enters loading
        // while the next track opens. The session must stay `playing` so the
        // foreground service isn't demoted mid-transition — and the media item
        // must already reflect the track being loaded.
        await controller.playTracks(<Track>[_track('a'), _track('b')]);
        await _settle();

        controller.emit(controller.state.copyWith(
          currentTrack: _track('b'),
          status: PlaybackStatus.loading,
        ));
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isTrue);
        expect(state.processingState, audio.AudioProcessingState.loading);
        expect(handler.mediaItem.value?.id, 'b');
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
      test('root lists the library categories and Queue', () async {
        final children = await handler.getChildren(MediaId.root);

        // No playlists/favorites/downloads wired here, so just the always-on
        // library categories plus Queue.
        expect(children.map((i) => i.id), [
          MediaId.library,
          MediaId.albums,
          MediaId.artists,
          MediaId.queue,
        ]);
        expect(children.map((i) => i.title),
            ['Songs', 'Albums', 'Artists', 'Queue']);
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

      test('albums are browsable containers; opening one lists playable tracks',
          () async {
        final albums = await handler.getChildren(MediaId.albums);
        // Each _track('x') has album 'Album x', so there is one album per track.
        expect(albums, hasLength(3));
        expect(albums.every((i) => i.playable == false), isTrue);

        final tracks = await handler.getChildren(albums.first.id);
        expect(tracks, isNotEmpty);
        expect(tracks.every((i) => i.playable == true), isTrue);
      });

      test('selecting an album track plays the album queue', () async {
        final albums = await handler.getChildren(MediaId.albums);
        final albumTracks = await handler.getChildren(albums.first.id);

        await handler.playFromMediaId(albumTracks.first.id);
        await _settle();

        expect(controller.state.currentTrack, isNotNull);
        expect(controller.playedTracks, isNotEmpty);
      });

      test(
          'artists are browsable containers; opening one lists playable tracks',
          () async {
        final artists = await handler.getChildren(MediaId.artists);
        expect(artists, hasLength(3));
        expect(artists.every((i) => i.playable == false), isTrue);

        final tracks = await handler.getChildren(artists.first.id);
        expect(tracks, isNotEmpty);
        expect(tracks.every((i) => i.playable == true), isTrue);
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

    group('offline & favorites browsing', () {
      late FakePlaybackController offController;
      late LinthraAudioHandler offHandler;

      setUp(() {
        offController = FakePlaybackController();
        offHandler = LinthraAudioHandler(
          offController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: _library),
            favorites: FakeFavoritesRepository({'a'}),
            downloads: FakeDownloadRepository({'b', 'c'}),
          ),
        );
      });

      tearDown(() async {
        await offHandler.dispose();
        await offController.dispose();
      });

      test('root surfaces Favorites and Offline when the user has some',
          () async {
        final ids =
            (await offHandler.getChildren(MediaId.root)).map((i) => i.id);
        expect(
            ids,
            containsAllInOrder(<String>[
              MediaId.favorites,
              MediaId.offline,
            ]));
      });

      test('offline lists the downloaded tracks; selecting one plays it',
          () async {
        final offline = await offHandler.getChildren(MediaId.offline);
        expect(offline.map((i) => i.title), ['Song b', 'Song c']);
        expect(offline.every((i) => i.playable == true), isTrue);

        await offHandler.playFromMediaId(offline.first.id);
        await _settle();
        expect(offController.state.currentTrack?.id, 'b');
        // The offline section seeds the queue with the offline list.
        expect(offController.state.upNext.map((t) => t.id), ['c']);
      });
    });

    group('media-session queue (car / head-unit Up Next)', () {
      test('publishes the queue as history + current + up-next, in order',
          () async {
        // Start at the middle track so there is both history and up-next.
        await controller.playTracks(_library, startIndex: 1);
        await _settle();

        // history (a), current (b), up-next (c) — the flat order a head unit's
        // Up Next list shows and skipToQueueItem indexes into.
        expect(handler.queue.value.map((i) => i.id), ['a', 'b', 'c']);
        // The now-playing item shares its id with its queue row, so the car
        // highlights the right row.
        expect(handler.mediaItem.value?.id, 'b');
      });

      test('republishes the queue on an edit, not on a position tick',
          () async {
        await controller.playTracks(<Track>[_track('a'), _track('b')]);
        await _settle();

        final List<List<audio.MediaItem>> pushes = <List<audio.MediaItem>>[];
        final sub = handler.queue.listen(pushes.add);
        addTearDown(sub.cancel);
        await _settle();
        // Listening replays the current value; count only pushes after that.
        final int baseline = pushes.length;

        // Position ticks don't change the queue contents → no new push.
        for (int ms = 200; ms <= 800; ms += 200) {
          controller.emit(
            controller.state.copyWith(position: Duration(milliseconds: ms)),
          );
          await _settle();
        }
        expect(pushes.length, baseline);

        // Adding a track grows up-next → exactly the queue is re-published.
        controller.addToQueue(_track('c'));
        await _settle();
        expect(pushes.length, greaterThan(baseline));
        expect(pushes.last.map((i) => i.id), ['a', 'b', 'c']);
      });

      test('skipToQueueItem jumps forward to an up-next row', () async {
        await controller.playTracks(_library); // a current, [b, c] up-next
        await _settle();

        // queue = [a, b, c]; row 2 is up-next 'c'.
        await handler.skipToQueueItem(2);
        await _settle();

        expect(controller.state.currentTrack?.id, 'c');
        expect(handler.mediaItem.value?.id, 'c');
      });

      test('skipToQueueItem steps back to a history row', () async {
        await controller.playTracks(_library);
        await controller.skipToNext();
        await controller.skipToNext(); // current c, history [a, b]
        await _settle();

        // queue = [a, b, c]; row 0 is history 'a'.
        await handler.skipToQueueItem(0);
        await _settle();

        expect(controller.state.currentTrack?.id, 'a');
        expect(handler.mediaItem.value?.id, 'a');
      });

      test('skipToQueueItem on the current row leaves it playing', () async {
        await controller.playTracks(_library);
        await controller.skipToNext(); // current b, history [a]
        await _settle();
        final int playedBefore = controller.playedTracks.length;

        await handler.skipToQueueItem(1); // row 1 == current

        await _settle();
        expect(controller.state.currentTrack?.id, 'b');
        expect(controller.playedTracks.length, playedBefore);
      });

      test('skipToQueueItem out of range is a safe no-op', () async {
        await controller.playTracks(_library);
        await _settle();
        final int playedBefore = controller.playedTracks.length;

        await handler.skipToQueueItem(99);
        await handler.skipToQueueItem(-1);
        await _settle();

        expect(controller.state.currentTrack?.id, 'a');
        expect(controller.playedTracks.length, playedBefore);
      });
    });

    group('car skip keeps the queue & metadata correct', () {
      test('skipToNext updates the current media item', () async {
        await controller.playTracks(_library);
        await _settle();
        expect(handler.mediaItem.value?.id, 'a');

        await handler.skipToNext();
        await _settle();

        expect(handler.mediaItem.value?.id, 'b');
        expect(handler.mediaItem.value?.title, 'Song b');
        expect(handler.mediaItem.value?.artist, 'Artist b');
      });

      test('skipToPrevious updates the current media item', () async {
        await controller.playTracks(_library, startIndex: 1);
        await _settle();
        expect(handler.mediaItem.value?.id, 'b');

        await handler.skipToPrevious();
        await _settle();

        expect(handler.mediaItem.value?.id, 'a');
      });

      test('a queue selected from the car supports next & previous', () async {
        // Selecting a library track in the car builds the queue (the rest of
        // the library becomes up-next), then car skip moves within that queue.
        await handler.playFromMediaId(MediaId.libraryTrack('a'));
        await _settle();
        expect(handler.mediaItem.value?.id, 'a');

        await handler.skipToNext();
        await _settle();
        expect(controller.state.currentTrack?.id, 'b');
        expect(handler.mediaItem.value?.id, 'b');

        await handler.skipToPrevious();
        await _settle();
        expect(controller.state.currentTrack?.id, 'a');
      });

      test('car Next at the end and Previous at the start are safe no-ops',
          () async {
        await controller.playTracks(<Track>[_track('a')]); // single track
        await _settle();

        await handler.skipToNext();
        await handler.skipToPrevious();
        await _settle();

        expect(controller.state.currentTrack?.id, 'a');
        expect(controller.skipCount, 1);
        expect(controller.previousCount, 1);
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

      test('now-playing item and queue rows are token-free, with no extras',
          () async {
        // The same secret-free guarantee must hold for what the car shows while
        // playing — the now-playing media item and every published queue row —
        // not just the browse tree.
        final playController = FakePlaybackController();
        final playHandler = LinthraAudioHandler(
          playController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: <Track>[jellyfin, local]),
          ),
        );
        addTearDown(() async {
          await playHandler.dispose();
          await playController.dispose();
        });

        await playController.playTracks(<Track>[jellyfin, local]);
        await _settle();

        final nowPlaying = playHandler.mediaItem.value;
        expect(nowPlaying, isNotNull);
        // The id is the opaque catalog id, never the `jellyfin:` uri.
        expect(nowPlaying!.id, 'jf-guid-123');

        final queueRows = playHandler.queue.value;
        expect(queueRows.map((i) => i.id), ['jf-guid-123', 'local-1']);

        for (final item in <audio.MediaItem>[nowPlaying, ...queueRows]) {
          expect(item.id, isNot(contains('api_key')));
          expect(item.id.toLowerCase(), isNot(contains('token')));
          expect(item.id, isNot(contains('jellyfin:')));
          expect(item.id, isNot(contains('://')));
          expect(item.extras, isNull);
          final String art = item.artUri?.toString() ?? '';
          expect(art, isNot(contains('api_key')));
          expect(art.toLowerCase(), isNot(contains('token')));
        }
      });

      test('album containers carry token-free art and no extras', () async {
        final albController = FakePlaybackController();
        final albHandler = LinthraAudioHandler(
          albController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: <Track>[jellyfin, local]),
          ),
        );
        addTearDown(() async {
          await albHandler.dispose();
          await albController.dispose();
        });

        final albums = await albHandler.getChildren(MediaId.albums);
        expect(albums, isNotEmpty);
        for (final item in albums) {
          // Browsable container: not playable, but may carry the album's
          // token-free cover art for the car row.
          expect(item.playable, isFalse);
          expect(item.extras, isNull);
          expect(item.id, isNot(contains('jellyfin:')));
          expect(item.id, isNot(contains('://')));
          final String art = item.artUri?.toString() ?? '';
          expect(art, isNot(contains('api_key')));
          expect(art.toLowerCase(), isNot(contains('token')));
        }
      });
    });
  });
}
