import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_artwork_source.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/fake_playback_controller.dart';
import 'fake_browse_repositories.dart';

/// A synchronous [MediaArtworkSource] that returns the covers it's been warmed
/// with and records every lookup, so tests can prove the handler reads the cache
/// by the credential-free reference (and not at all for platform-loadable art).
class _RecordingArtworkSource implements MediaArtworkSource {
  _RecordingArtworkSource([Map<Uri, Uri>? cache])
      : _cache = cache ?? <Uri, Uri>{};

  final Map<Uri, Uri> _cache;
  final List<Uri> queries = <Uri>[];
  final StreamController<Uri> _coverReady = StreamController<Uri>.broadcast();

  /// Simulates the prewarm service finishing a fetch for [reference]: the cover
  /// becomes cached and the ready event fires (as the real cache does).
  void warm(Uri reference, Uri local) {
    _cache[reference] = local;
    _coverReady.add(reference);
  }

  @override
  Uri? cached(Uri reference) {
    queries.add(reference);
    return _cache[reference];
  }

  @override
  Stream<Uri> get coverReady => _coverReady.stream;

  Future<void> close() => _coverReady.close();
}

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

    group('media-session artwork stays loadable (no opaque refs reach artUri)',
        () {
      Future<Uri?> artUriFor(Uri? artworkUri) async {
        await controller.playTracks(<Track>[
          Track(
              id: 'x',
              title: 'Song',
              uri: 'subsonic:x',
              artworkUri: artworkUri),
        ]);
        await _settle();
        return handler.mediaItem.value?.artUri;
      }

      test('drops an opaque subsonic-cover: reference to null', () async {
        // The OS fetches MediaItem.artUri itself and can't reach the in-app
        // resolver, so a custom-scheme reference must not reach the session (it
        // would fail/log on the bad URI); null cleanly shows no art, as before.
        expect(await artUriFor(Uri.parse('subsonic-cover:al-1')), isNull);
      });

      test('passes a Jellyfin token-free http(s) cover through', () async {
        final art = Uri.parse('https://jelly.example/Items/1/Images/Primary');
        expect(await artUriFor(art), art);
      });

      test('passes a local file: embedded cover through', () async {
        final art = Uri.parse('file:///cache/linthra_local_artwork/a.img');
        expect(await artUriFor(art), art);
      });
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

    group('Bluetooth / car media-session surface', () {
      // A Bluetooth headset, a car head unit, and the lock screen all drive the
      // same MediaSession. These lock in the device-facing invariants the audit
      // verified (see docs/audio-bluetooth-cpu-audit.md): a stable capability
      // set, artwork in the now-playing item when the track has it, and a Stop
      // control that is always offered.

      test('advertises the full transport capability set even on one track',
          () async {
        // A single-track queue has no next/previous, so the *visible* controls
        // omit skip (asserted above) — but the session must still advertise the
        // skip capabilities steadily, so a head unit / Bluetooth device that
        // cached them at connect time keeps its Next / Previous and queue-row
        // buttons live regardless of position in the queue.
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        expect(
          handler.playbackState.value.systemActions,
          containsAll(<audio.MediaAction>{
            audio.MediaAction.seek,
            audio.MediaAction.skipToNext,
            audio.MediaAction.skipToPrevious,
            audio.MediaAction.skipToQueueItem,
          }),
        );
      });

      test('mirrors artwork into the now-playing item when the track has it',
          () async {
        final withArt = Track(
          id: 'art',
          title: 'Song art',
          uri: '/art.mp3',
          artistName: 'Artist art',
          albumName: 'Album art',
          artworkUri: Uri.parse('https://music.example.com/art/primary'),
        );
        await controller.playTracks(<Track>[withArt]);
        await _settle();

        expect(
          handler.mediaItem.value?.artUri,
          Uri.parse('https://music.example.com/art/primary'),
        );
      });

      test('omits artwork when the track has none ("when available")',
          () async {
        // _track('a') carries no artworkUri.
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        expect(handler.mediaItem.value, isNotNull);
        expect(handler.mediaItem.value?.artUri, isNull);
      });

      test('always offers the Stop control, playing and paused', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();
        expect(
          handler.playbackState.value.controls,
          contains(audio.MediaControl.stop),
        );

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.paused),
        );
        await _settle();
        expect(
          handler.playbackState.value.controls,
          contains(audio.MediaControl.stop),
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

    group('Subsonic media-session artwork (privacy-safe local cache)', () {
      // A Subsonic track persists a *credential-free* reference in artworkUri
      // (subsonic-cover:<id>). The platform media session loads artUri itself —
      // somewhere Linthra can't add the salt+token — so the handler attaches a
      // *pre-warmed local* cover (a file: the MediaArtworkPrewarmService cached
      // ahead of time), never the reference and never the getCoverArt URL. The
      // read is synchronous, so a warmed cover is present on the very first push
      // (beating a head unit's metadata snapshot) and nothing fetches on the
      // playback path.
      final subsonic = Track(
        id: 'sub-1',
        title: 'Sub Song',
        uri: 'subsonic:sub-1',
        artistName: 'Sub Artist',
        albumName: 'Sub Album',
        artworkUri: Uri.parse('subsonic-cover:al-9'),
      );
      final reference = Uri.parse('subsonic-cover:al-9');
      // What the cache hands back: a credential-free FileProvider content:// URI
      // over the cached cover, which the platform session can read.
      final localArt = Uri.parse(
        'content://io.github.thezupzup.linthra.mediaartwork/media_artwork/'
        'abc.img',
      );

      LinthraAudioHandler handlerWith(
        FakePlaybackController c,
        List<Track> tracks, {
        MediaArtworkSource? artwork,
      }) {
        final h = LinthraAudioHandler(
          c,
          MediaBrowserTree(FakeMusicLibraryRepository(tracks: tracks)),
          artwork: artwork,
        );
        addTearDown(() async {
          await h.dispose();
          await c.dispose();
          if (artwork is _RecordingArtworkSource) await artwork.close();
        });
        return h;
      }

      test(
          'shows a pre-warmed cover as a safe local file artUri on the first '
          'push', () async {
        final source = _RecordingArtworkSource(<Uri, Uri>{reference: localArt});
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle(); // a single broadcast — the read is synchronous

        // The now-playing item — what the lock screen / Android Auto card shows
        // — carries the safe local cover, present immediately (snapshot-safe).
        expect(h.mediaItem.value?.id, 'sub-1');
        expect(h.mediaItem.value?.artUri, localArt);
        // It was looked up by the credential-free reference, nothing else.
        expect(source.queries, contains(reference));
      });

      test(
          'the now-playing artUri is a safe file:, never the reference or a '
          'credential', () async {
        final source = _RecordingArtworkSource(<Uri, Uri>{reference: localArt});
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        final String art = h.mediaItem.value?.artUri?.toString() ?? '';
        expect(art, startsWith('content:'));
        expect(art, isNot(contains('subsonic-cover')));
        expect(art.toLowerCase(), isNot(contains('getcoverart')));
        expect(art.toLowerCase(), isNot(contains('token')));
        expect(art.toLowerCase(), isNot(contains('u=')));
        expect(art.toLowerCase(), isNot(contains('t=')));
        expect(art.toLowerCase(), isNot(contains('s=')));
      });

      test('an un-warmed cover leaves artUri null without affecting playback',
          () async {
        // The cover isn't cached yet (or couldn't be): artUri is null, never the
        // reference, and the rest of the now-playing metadata is intact.
        final source = _RecordingArtworkSource(); // empty cache
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        final item = h.mediaItem.value;
        expect(item, isNotNull);
        expect(item!.id, 'sub-1'); // metadata intact, playback unaffected
        expect(item.title, 'Sub Song');
        expect(item.artUri, isNull); // no artwork, and crucially no leak
      });

      test(
          'a cover warmed mid-track appears immediately via coverReady, no '
          'position tick needed', () async {
        // The cold first-track case: the cover finishes warming after the card
        // is published art-less. The coverReady event re-publishes the item at
        // once — no waiting for the next playback tick (the residual delay fix).
        final source = _RecordingArtworkSource(); // empty at first
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();
        expect(h.mediaItem.value?.artUri, isNull);

        // The prewarm completes out of band → cover cached + coverReady fires.
        // No position tick is emitted; the cover must still appear.
        source.warm(reference, localArt);
        await _settle();

        expect(h.mediaItem.value?.artUri, localArt);
      });

      test('coverReady for the current track re-publishes only once (no loop)',
          () async {
        // The re-publish must be a single, gated push: one item with art, never
        // a tight loop of re-broadcasts.
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        final List<audio.MediaItem?> pushes = <audio.MediaItem?>[];
        final sub = h.mediaItem.listen(pushes.add);
        addTearDown(sub.cancel);

        await c.playTracks(<Track>[subsonic]);
        await _settle();
        final int beforeWarm = pushes.length;

        source.warm(reference, localArt); // cover cached + coverReady
        await _settle();

        // Exactly one extra push — the item that gained the art.
        expect(pushes.length, beforeWarm + 1);
        expect(pushes.last?.artUri, localArt);

        // A duplicate coverReady for an already-shown cover is a no-op (the
        // _sameItem guard), so no further push.
        source.warm(reference, localArt);
        await _settle();
        expect(pushes.length, beforeWarm + 1);
      });

      test('a cover warm / MediaItem rebroadcast never calls play', () async {
        // #172 artwork must stay strictly off the playback path: when a cover
        // finishes warming, the handler re-publishes the now-playing MediaItem
        // so the art appears — but it must NOT touch transport. A rebroadcast
        // that resumed/started playback would be the "cover art restarted my
        // music" bug.
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        // The user paused; the now-playing item is published, art-less.
        await c.playTracks(<Track>[subsonic]);
        c.emit(c.state.copyWith(status: PlaybackStatus.paused));
        await _settle();
        final int playsBefore = c.playedTracks.length;
        final int playCountBefore = c.playCount;

        // The cover warms out of band → coverReady fires → the item is
        // re-broadcast with its art. No transport command may result.
        source.warm(reference, localArt);
        await _settle();

        // The art landed (the rebroadcast did its job) …
        expect(h.mediaItem.value?.artUri, localArt);
        // … but playback was never started/resumed by it, and stays paused.
        expect(c.playCount, playCountBefore);
        expect(c.playedTracks.length, playsBefore);
        expect(c.pauseCount, 0);
        expect(h.playbackState.value.playing, isFalse);
      });

      test(
          'coverReady for a non-current cover leaves the now-playing item alone',
          () async {
        // Warming an up-next cover must not disturb the current now-playing item.
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        // A different reference (some up-next cover) becomes ready.
        source.warm(Uri.parse('subsonic-cover:other'),
            Uri.parse('content://x/media_artwork/other.img'));
        await _settle();

        // The now-playing item is unchanged (still art-less for sub-1).
        expect(h.mediaItem.value?.id, 'sub-1');
        expect(h.mediaItem.value?.artUri, isNull);
      });

      test('without an artwork source, a reference never leaks into artUri',
          () async {
        // The default (a platform without the cache): the unloadable
        // subsonic-cover: reference must be dropped, not handed to the session.
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic]); // no artwork source

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        final item = h.mediaItem.value;
        expect(item, isNotNull);
        expect(item!.artUri, isNull);
        expect(
            item.artUri?.toString() ?? '', isNot(contains('subsonic-cover')));
      });

      test('browse-tree containers drop an un-warmed cover reference',
          () async {
        // Browse covers aren't pre-warmed, so a Subsonic album/artist
        // container's reference is dropped (null), never leaked as an unloadable
        // URI.
        final source = _RecordingArtworkSource(); // nothing cached
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        final albums = await h.getChildren(MediaId.albums);
        expect(albums, isNotEmpty);
        for (final item in albums) {
          expect(item.artUri, isNull);
          expect(
            item.artUri?.toString() ?? '',
            isNot(contains('subsonic-cover')),
          );
        }
      });

      test('Jellyfin http art and local file art pass through unchanged',
          () async {
        // A platform-loadable cover (Jellyfin token-free http, a local file:) is
        // forwarded unchanged, and the artwork source is never even consulted.
        final jf = Track(
          id: 'jf',
          title: 'JF',
          uri: 'jellyfin:jf',
          artworkUri:
              Uri.parse('https://music.example.com/Items/jf/Images/Primary'),
        );
        final loc = Track(
          id: 'loc',
          title: 'Loc',
          uri: '/music/loc.mp3',
          artworkUri: Uri.parse('file:///cache/linthra_local_artwork/loc.img'),
        );
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[jf, loc], artwork: source);

        await c.playTracks(<Track>[jf, loc]);
        await _settle();

        // Jellyfin token-free http art is used as-is.
        final nowPlayingArt = h.mediaItem.value?.artUri;
        expect(
          nowPlayingArt,
          Uri.parse('https://music.example.com/Items/jf/Images/Primary'),
        );
        // The local file: art rides on its queue row unchanged.
        final locRow = h.queue.value.firstWhere((i) => i.id == 'loc');
        expect(
          locRow.artUri,
          Uri.parse('file:///cache/linthra_local_artwork/loc.img'),
        );
        // Neither becomes a content:// URI, so they are never served by the
        // media-artwork FileProvider and its read-grant logic never runs for
        // Jellyfin/local covers — only Subsonic references go through the cache.
        expect(nowPlayingArt?.isScheme('content'), isFalse);
        expect(locRow.artUri?.isScheme('content'), isFalse);
        // The cover source is not consulted at all for platform-loadable covers.
        expect(source.queries, isEmpty);
      });
    });
  });
}
