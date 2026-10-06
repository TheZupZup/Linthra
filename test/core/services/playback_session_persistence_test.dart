import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';

import '../../features/player/fake_playback_controller.dart';

void main() {
  const Track remote = Track(
    id: '101',
    title: 'Remote',
    uri: 'jellyfin:101',
    duration: Duration(minutes: 3),
  );
  const Track localMissing = Track(
    id: '/missing/song.mp3',
    title: 'Gone',
    uri: '/missing/song.mp3',
    duration: Duration(minutes: 2),
  );
  const Track localOk = Track(
    id: '/tmp/linthra-session-test.mp3',
    title: 'Ok',
    uri: '/tmp/linthra-session-test.mp3',
    duration: Duration(minutes: 2),
  );

  group('PlaybackSessionPersistence', () {
    test('persists a paused/playing state and restores it without autoplay',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: remote,
        position: Duration(seconds: 33),
        duration: Duration(minutes: 3),
        upNext: <Track>[],
        previous: <Track>[],
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final PersistedPlaybackSession? saved = await store.load();
      expect(saved, isNotNull);
      expect(saved!.current!.uri, remote.uri);
      expect(saved.position, const Duration(seconds: 33));

      final FakePlaybackController restoredController =
          FakePlaybackController();
      final PlaybackSessionPersistence restorer = PlaybackSessionPersistence(
        store: store,
        controller: restoredController,
        playbackStates: restoredController.stateStream,
        localFileExists: (_) => true,
      );
      await restorer.restore();

      expect(restoredController.restoreSessionCount, 1);
      expect(restoredController.lastRestoreAutoplay, isFalse);
      expect(
          restoredController.lastRestorePosition, const Duration(seconds: 33));
      expect(restoredController.state.status, PlaybackStatus.paused);
      expect(restoredController.state.currentTrack?.uri, remote.uri);
      expect(restoredController.state.isPlaying, isFalse);

      await persistence.dispose();
      await restorer.dispose();
      await controller.dispose();
      await restoredController.dispose();
    });

    test('drops signed-out remote tracks and missing local files on restore',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[localMissing, remote, localOk],
          currentIndex: 1,
          position: Duration(seconds: 5),
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: const Stream<PlaybackState>.empty(),
        remoteAccountOf: (MusicProvider p) =>
            identical(p, MusicProviders.jellyfin) ? null : 'someone',
        localFileExists: (String uri) => uri == localOk.uri,
      );

      await persistence.restore();

      expect(controller.restoreSessionCount, 1);
      expect(controller.state.currentTrack?.uri, localOk.uri);
      expect(controller.state.upNext, isEmpty);
      expect(controller.state.isPlaying, isFalse);

      await persistence.dispose();
      await controller.dispose();
    });

    test('a wholly invalid session is cleared and does not restore', () async {
      // A record this build cannot read at all: an unknown schema version.
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[remote],
          currentIndex: 0,
          schemaVersion: PersistedPlaybackSession.currentSchemaVersion + 1,
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: const Stream<PlaybackState>.empty(),
        localFileExists: (_) => true,
      );

      await persistence.restore();

      expect(controller.restoreSessionCount, 0);
      expect(await store.load(), isNull);

      await persistence.dispose();
      await controller.dispose();
    });

    group('tracks unavailable at launch stay saved', () {
      // A file on a drive that isn't plugged in, or a server whose sign-in
      // couldn't be read from a locked keyring, is away for this launch, not
      // gone. Restore leaves it out of the engine, but the saved session has to
      // keep it for the launch it comes back on.
      const Track usbFirst = Track(
        id: '/media/usb/first.mp3',
        title: 'First',
        uri: '/media/usb/first.mp3',
        duration: Duration(minutes: 4),
      );
      const Track usbSecond = Track(
        id: '/media/usb/second.mp3',
        title: 'Second',
        uri: '/media/usb/second.mp3',
        duration: Duration(minutes: 4),
      );

      List<String> savedUris(PersistedPlaybackSession? session) =>
          <String>[for (final Track t in session!.tracks) t.uri];

      test('keeps a session whose local files are all missing', () async {
        final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
          const PersistedPlaybackSession(
            tracks: <Track>[usbFirst, usbSecond],
            currentIndex: 1,
            position: Duration(seconds: 20),
          ),
        );
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (_) => false,
          positionSaveInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        addTearDown(persistence.dispose);

        await persistence.restore();
        expect(controller.restoreSessionCount, 0);

        // The idle engine still publishes states (a volume step, a mute), and
        // none of them is the listener emptying a queue.
        controller.setVolume(0.4);
        controller.setMuted(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final PersistedPlaybackSession? kept = await store.load();
        expect(kept, isNotNull);
        expect(savedUris(kept), <String>[usbFirst.uri, usbSecond.uri]);
        expect(kept!.currentIndex, 1);
        expect(kept.position, const Duration(seconds: 20));
      });

      test('keeps a session whose server is unavailable at launch', () async {
        final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
          const PersistedPlaybackSession(
            tracks: <Track>[remote],
            currentIndex: 0,
            position: Duration(seconds: 9),
          ),
        );
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          remoteAccountOf: (_) => null,
          localFileExists: (_) => true,
          positionSaveInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        addTearDown(persistence.dispose);

        await persistence.restore();

        expect(controller.restoreSessionCount, 0);
        final PersistedPlaybackSession? kept = await store.load();
        expect(kept, isNotNull);
        expect(savedUris(kept), <String>[remote.uri]);
        expect(kept!.position, const Duration(seconds: 9));
      });

      test('a partial restore saves progress without dropping the rest',
          () async {
        final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
          const PersistedPlaybackSession(
            tracks: <Track>[localOk, usbFirst, remote, usbSecond],
            currentIndex: 0,
            position: Duration(seconds: 5),
          ),
        );
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (String uri) => uri == localOk.uri,
          positionSaveInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        addTearDown(persistence.dispose);

        await persistence.restore();
        expect(controller.state.currentTrack?.uri, localOk.uri);
        expect(controller.state.upNext.map((Track t) => t.uri),
            <String>[remote.uri]);

        // The engine settling on the restored track, then position ticks.
        controller.emit(controller.state.copyWith(
          position: const Duration(seconds: 6),
        ));
        await Future<void>.delayed(Duration.zero);
        controller.emit(controller.state.copyWith(
          position: const Duration(seconds: 7),
        ));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        PersistedPlaybackSession? saved = await store.load();
        expect(savedUris(saved),
            <String>[localOk.uri, usbFirst.uri, remote.uri, usbSecond.uri]);
        expect(saved!.currentIndex, 0);
        expect(saved.position, const Duration(seconds: 7));

        // Moving on through the restored queue is progress, not a new queue:
        // it lands on the same track in the full saved one.
        await controller.skipToNext();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        saved = await store.load();
        expect(savedUris(saved),
            <String>[localOk.uri, usbFirst.uri, remote.uri, usbSecond.uri]);
        expect(saved!.currentIndex, 2);
      });

      test('a partial restore standing in for a missing current track keeps it',
          () async {
        final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
          const PersistedPlaybackSession(
            tracks: <Track>[usbFirst, localOk, remote],
            currentIndex: 0,
            position: Duration(seconds: 30),
          ),
        );
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (String uri) => uri == localOk.uri,
          positionSaveInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        addTearDown(persistence.dispose);

        await persistence.restore();
        // The engine lands on the first track it can play, in place of the
        // missing one.
        expect(controller.state.currentTrack?.uri, localOk.uri);

        controller.emit(controller.state.copyWith(
          position: const Duration(seconds: 31),
        ));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        PersistedPlaybackSession? saved = await store.load();
        expect(
            savedUris(saved), <String>[usbFirst.uri, localOk.uri, remote.uri]);
        expect(saved!.currentIndex, 0);
        expect(saved.position, const Duration(seconds: 30));

        // Once the listener moves on, the saved session follows them.
        await controller.skipToNext();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        saved = await store.load();
        expect(
            savedUris(saved), <String>[usbFirst.uri, localOk.uri, remote.uri]);
        expect(saved!.currentIndex, 2);
      });

      test('a queue the listener picks afterwards is saved as it is', () async {
        final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
          const PersistedPlaybackSession(
            tracks: <Track>[localOk, usbFirst],
            currentIndex: 0,
          ),
        );
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (String uri) => uri == localOk.uri,
          positionSaveInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        addTearDown(persistence.dispose);

        await persistence.restore();
        await Future<void>.delayed(Duration.zero);

        await controller.playTracks(<Track>[remote]);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(savedUris(await store.load()), <String>[remote.uri]);
      });

      test('a new queue after a restore that found nothing is saved', () async {
        final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
          const PersistedPlaybackSession(
            tracks: <Track>[usbFirst],
            currentIndex: 0,
          ),
        );
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (_) => false,
          positionSaveInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        addTearDown(persistence.dispose);

        await persistence.restore();
        await controller.playTracks(<Track>[remote]);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(savedUris(await store.load()), <String>[remote.uri]);
      });
    });

    test('clears persistence when playback becomes idle without a track',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: remote,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(await store.load(), isNotNull);

      controller.emit(PlaybackState.idle);
      await Future<void>.delayed(Duration.zero);
      expect(await store.load(), isNull);

      await persistence.dispose();
      await controller.dispose();
    });

    group('position saves are coalesced (battery)', () {
      // Every save re-encodes the whole logical queue and rewrites the store's
      // single document. A run of position ticks — several a second while
      // playing — must therefore cost exactly one write, and that write must
      // carry the position at the moment it happens rather than the older one
      // that armed the timer.
      test('a run of ticks costs one save, carrying the freshest position',
          () async {
        final _CountingStore store = _CountingStore();
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (_) => true,
          positionSaveInterval: const Duration(milliseconds: 40),
        );

        controller.emit(const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: remote,
          position: Duration(seconds: 1),
        ));
        await Future<void>.delayed(Duration.zero);
        // The first emission is a structural change (a new track): it persists
        // straight away, and only the ticks after it are debounced.
        final int structuralSaves = store.saves;
        expect(structuralSaves, 1);

        for (int second = 2; second <= 6; second++) {
          controller.emit(PlaybackState(
            status: PlaybackStatus.playing,
            currentTrack: remote,
            position: Duration(seconds: second),
          ));
          await Future<void>.delayed(Duration.zero);
        }
        expect(store.saves, structuralSaves,
            reason: 'ticks inside the interval must not each write');

        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(store.saves, structuralSaves + 1);
        expect((await store.load())!.position, const Duration(seconds: 6));

        await persistence.dispose();
        await controller.dispose();
      });

      test('a clean shutdown persists the position still waiting', () async {
        final _CountingStore store = _CountingStore();
        final FakePlaybackController controller = FakePlaybackController();
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (_) => true,
          positionSaveInterval: const Duration(minutes: 1),
        );

        controller.emit(const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: remote,
          position: Duration(seconds: 1),
        ));
        await Future<void>.delayed(Duration.zero);
        controller.emit(const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: remote,
          position: Duration(seconds: 42),
        ));
        await Future<void>.delayed(Duration.zero);

        // Quitting the app mustn't throw away where playback actually was just
        // because the debounce hadn't elapsed.
        await persistence.dispose();
        expect((await store.load())!.position, const Duration(seconds: 42));

        await controller.dispose();
      });
    });

    group('a queue that ran out', () {
      // The queue is saved as it plays, and a queue that ran out (an album
      // heard to the end, then the app closed) is the last thing saved.
      const Track first = Track(
        id: '/music/1.flac',
        title: 'One',
        uri: '/music/1.flac',
        duration: _EndingEngine.length,
      );
      const Track last = Track(
        id: '/music/2.flac',
        title: 'Two',
        uri: '/music/2.flac',
        duration: _EndingEngine.length,
      );
      const Track queuedAfter = Track(
        id: '/music/3.flac',
        title: 'Three',
        uri: '/music/3.flac',
        duration: _EndingEngine.length,
      );

      /// Plays [first, last] to the end (then queues [then], when given),
      /// quits, launches again, presses Play and listens for a second.
      /// Returns what is playing then.
      Future<PlaybackState> relaunchAndPlay({Track? then}) async {
        final InMemoryPlaybackSessionStore store =
            InMemoryPlaybackSessionStore();
        final _EndingEngine engine = _EndingEngine();
        final JustAudioPlaybackController controller =
            JustAudioPlaybackController(
                player: engine, resolver: _LocalResolver());
        final PlaybackSessionPersistence persistence =
            PlaybackSessionPersistence(
          store: store,
          controller: controller,
          playbackStates: controller.stateStream,
          localFileExists: (_) => true,
          positionSaveInterval: Duration.zero,
        );
        await controller.playTracks(<Track>[first, last]);
        await pumpEventQueue();
        for (int track = 0; track < 2; track++) {
          // The last position the engine reported, then the end.
          controller.setPositionForTesting(
              _EndingEngine.length - const Duration(milliseconds: 200));
          await pumpEventQueue();
          engine.advance(_EndingEngine.length);
          await pumpEventQueue();
        }
        expect(controller.state.status, PlaybackStatus.completed);
        expect(controller.state.currentTrack, last);
        if (then != null) {
          controller.addToQueue(then);
          await pumpEventQueue();
        }
        await persistence.dispose();
        await controller.dispose();

        // The next launch.
        final _EndingEngine nextEngine = _EndingEngine();
        final JustAudioPlaybackController restored =
            JustAudioPlaybackController(
                player: nextEngine, resolver: _LocalResolver());
        final PlaybackSessionPersistence restorer = PlaybackSessionPersistence(
          store: store,
          controller: restored,
          playbackStates: restored.stateStream,
          localFileExists: (_) => true,
        );
        addTearDown(restored.dispose);
        addTearDown(restorer.dispose);
        await restorer.restore();
        await pumpEventQueue();

        await restored.play();
        await pumpEventQueue();
        nextEngine.advance(const Duration(seconds: 1));
        await pumpEventQueue();
        return restored.state;
      }

      test('comes back ready to play from the top, not at its very end',
          () async {
        // Put back paused at the end of its last track, the first Play after
        // the next launch played that track's last instant and ran out
        // again: nothing to hear until a second Play.
        final PlaybackState playing = await relaunchAndPlay();

        expect(playing.status, PlaybackStatus.playing,
            reason: 'Play after the relaunch ran the queue out again at once');
        // What Play does after the end without a relaunch, too.
        expect(playing.currentTrack, first);
      });

      test('comes back on a track queued after the end', () async {
        final PlaybackState playing = await relaunchAndPlay(then: queuedAfter);

        expect(playing.status, PlaybackStatus.playing);
        expect(playing.currentTrack, queuedAfter);
      });
    });

    test('restore comes back on the saved entry, not an earlier copy of it',
        () async {
      // A queue can hold the same song twice: one queued again with "Add to
      // queue", an album queued after one of its songs, a playlist repeat.
      const Track a = Track(
        id: 'a',
        title: 'Song A',
        uri: 'jellyfin:a',
        duration: Duration(minutes: 4),
      );
      const Track b = Track(id: 'b', title: 'Song B', uri: 'jellyfin:b');
      const Track c = Track(id: 'c', title: 'Song C', uri: 'jellyfin:c');
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController before = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: before,
        playbackStates: before.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );

      // The second A of [A, B, A, C] is playing.
      before.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: a,
        position: Duration(seconds: 90),
        duration: Duration(minutes: 4),
        previous: <Track>[a, b],
        upNext: <Track>[c],
        hasPrevious: true,
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect((await store.load())!.currentIndex, 2);

      // Next launch.
      final FakePlaybackController after = FakePlaybackController();
      final PlaybackSessionPersistence restorer = PlaybackSessionPersistence(
        store: store,
        controller: after,
        playbackStates: after.stateStream,
        localFileExists: (_) => true,
      );
      await restorer.restore();

      // Back on that entry: A and B behind it, only C ahead, rather than on
      // the first A with B and A to hear again.
      expect(
        after.state.previous.map((Track t) => t.uri),
        <String>[a.uri, b.uri],
      );
      expect(after.state.upNext.map((Track t) => t.uri), <String>[c.uri]);
      expect(after.lastRestorePosition, const Duration(seconds: 90));

      await persistence.dispose();
      await restorer.dispose();
      await before.dispose();
      await after.dispose();
    });

    test(
        'a stored pre-shuffle order that is not the queue\'s own is not '
        'trusted', () async {
      // A record whose pre-shuffle order ('o') does not hold the songs of
      // the queue ('t'): written by hand, damaged on disk, or left by another
      // build. Nothing in Linthra writes one, but restore reads it.
      const Track x = Track(
        id: '/music/x.flac',
        title: 'X',
        uri: '/music/x.flac',
        duration: _EndingEngine.length,
      );
      const Track y = Track(
        id: '/music/y.flac',
        title: 'Y',
        uri: '/music/y.flac',
        duration: _EndingEngine.length,
      );
      const Track z = Track(
        id: '/music/z.flac',
        title: 'Z',
        uri: '/music/z.flac',
        duration: _EndingEngine.length,
      );
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[x, y, z],
          currentIndex: 1,
          shuffleEnabled: true,
          originalOrder: <Track>[z, x],
        ),
      );
      final _EndingEngine engine = _EndingEngine();
      final List<Track> completed = <Track>[];
      final JustAudioPlaybackController controller =
          JustAudioPlaybackController(
        player: engine,
        resolver: _LocalResolver(),
        onTrackCompleted: completed.add,
      );
      final PlaybackSessionPersistence restorer = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
      );
      addTearDown(controller.dispose);
      addTearDown(restorer.dispose);
      await restorer.restore();
      await pumpEventQueue();
      expect(controller.state.currentTrack, y);

      // The listener plays Y and turns shuffle off while it plays.
      await controller.play();
      await pumpEventQueue();
      controller.setShuffleEnabled(false);
      await pumpEventQueue();
      expect(controller.state.currentTrack, y);
      expect(
        <Track>[
          ...controller.state.previous,
          controller.state.currentTrack!,
          ...controller.state.upNext,
        ],
        containsAll(<Track>[x, y, z]),
        reason: 'shuffle off must not take the playing song out of the queue',
      );

      // Y plays to its end.
      engine.advance(_EndingEngine.length);
      await pumpEventQueue();

      expect(completed, <Track>[y],
          reason: 'the song that played is the one recorded as played');
    });

    test('saves a queue holding a local song whose path says "bearer "',
        () async {
      const Track yesterday = Track(
        id: '/home/me/Music/Other/01 - Yesterday.flac',
        title: 'Yesterday',
        uri: '/home/me/Music/Other/01 - Yesterday.flac',
      );
      const Track today = Track(
        id: '/home/me/Music/Other/02 - Today.flac',
        title: 'Today',
        uri: '/home/me/Music/Other/02 - Today.flac',
        duration: Duration(minutes: 4),
      );
      const Track pallbearer = Track(
        id: '/home/me/Music/Pallbearer - Heartless/01 - I Saw the End.flac',
        title: 'I Saw the End',
        uri: '/home/me/Music/Pallbearer - Heartless/01 - I Saw the End.flac',
      );
      // Yesterday's queue, saved by an earlier session.
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[yesterday],
          currentIndex: 0,
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );

      // Today's queue, a Pallbearer song in it.
      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: today,
        position: Duration(seconds: 42),
        duration: Duration(minutes: 4),
        upNext: <Track>[pallbearer],
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Today's queue is what a restart brings back, not yesterday's.
      final PersistedPlaybackSession? saved = await store.load();
      expect(
        saved?.tracks.map((Track t) => t.uri),
        <String>[today.uri, pallbearer.uri],
      );
      expect(saved?.current?.uri, today.uri);

      await persistence.dispose();
      await controller.dispose();
    });

    test('restore failure clears the store and never throws', () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[remote],
          currentIndex: 0,
        ),
      );
      final _ThrowingRestoreController controller =
          _ThrowingRestoreController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: const Stream<PlaybackState>.empty(),
        localFileExists: (_) => true,
      );

      await expectLater(persistence.restore(), completes);
      expect(await store.load(), isNull);

      await persistence.dispose();
      await controller.dispose();
    });
    test('a volume-only change on a paused track writes nothing', () async {
      // The session document has no volume or mute field, so re-saving it for
      // a slider step would be a disk write per pointer move.
      final _CountingStore store = _CountingStore();
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );
      addTearDown(persistence.dispose);
      addTearDown(controller.dispose);

      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: remote,
        position: Duration(seconds: 12),
        duration: Duration(minutes: 3),
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final int afterFirst = store.saves;
      expect(afterFirst, greaterThan(0));

      controller.setVolume(0.6);
      controller.setVolume(0.5);
      controller.setMuted(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(store.saves, afterFirst);

      // A real move still persists.
      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: remote,
        position: Duration(seconds: 40),
        duration: Duration(minutes: 3),
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(store.saves, greaterThan(afterFirst));
    });
  });

  group("another account's songs (#767)", () {
    // A remote track id only means something on its own server: restored
    // under another account, `subsonic:1` would ask that server for its own
    // song 1, under this one's title.
    const Track sub1 = Track(
      id: '1',
      title: 'Alice one',
      uri: 'subsonic:1',
      duration: Duration(minutes: 3),
    );
    const Track sub2 = Track(
      id: '2',
      title: 'Alice two',
      uri: 'subsonic:2',
      duration: Duration(minutes: 3),
    );
    const Track plex7 = Track(
      id: '7',
      title: 'Server A seven',
      uri: 'plex:7',
      duration: Duration(minutes: 3),
    );

    List<String> savedUris(PersistedPlaybackSession? session) =>
        <String>[for (final Track t in session!.tracks) t.uri];

    Future<void> settle() async {
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    PlaybackSessionPersistence persistenceFor(
      InMemoryPlaybackSessionStore store,
      FakePlaybackController controller, {
      required String? Function(MusicProvider provider) signedInAs,
      Future<String?> Function(MusicProvider provider)? queueOwnerOf,
      Duration positionSaveInterval = Duration.zero,
    }) {
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        remoteAccountOf: signedInAs,
        queueOwnerOf: queueOwnerOf,
        localFileExists: (_) => true,
        positionSaveInterval: positionSaveInterval,
      );
      addTearDown(controller.dispose);
      addTearDown(persistence.dispose);
      return persistence;
    }

    test("a save records whose songs each provider's tracks are", () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      final List<MusicProvider> asked = <MusicProvider>[];
      persistenceFor(
        store,
        controller,
        signedInAs: (_) => 'alice',
        queueOwnerOf: (MusicProvider provider) async {
          asked.add(provider);
          return identical(provider, MusicProviders.plex)
              ? 'server-a'
              : 'alice';
        },
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: sub1,
        upNext: <Track>[localOk, plex7],
      ));
      await settle();

      final PersistedPlaybackSession? saved = await store.load();
      expect(saved!.owners, <String, String>{
        'subsonic': 'alice',
        'plex': 'server-a',
      });
      // Only the providers in the queue are asked; a local file is nobody's.
      expect(asked.toSet(), <MusicProvider>{
        MusicProviders.subsonic,
        MusicProviders.plex,
      });
    });

    test('restored under another account, its songs wait in the record',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[sub1, localOk, sub2],
          currentIndex: 0,
          position: Duration(seconds: 12),
          owners: <String, String>{'subsonic': 'alice'},
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence =
          persistenceFor(store, controller, signedInAs: (_) => 'bob');

      await persistence.restore();
      await settle();

      expect(controller.state.currentTrack?.uri, localOk.uri);
      expect(controller.state.previous, isEmpty);
      expect(controller.state.upNext, isEmpty);
      // Kept for when alice is back, and still recorded as hers.
      final PersistedPlaybackSession? kept = await store.load();
      expect(savedUris(kept), <String>[sub1.uri, localOk.uri, sub2.uri]);
      expect(kept!.owners, <String, String>{'subsonic': 'alice'});
    });

    test('restored under the same account, they come back', () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[sub1, localOk, sub2],
          currentIndex: 0,
          owners: <String, String>{'subsonic': 'alice'},
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence =
          persistenceFor(store, controller, signedInAs: (_) => 'alice');

      await persistence.restore();

      expect(controller.state.currentTrack?.uri, sub1.uri);
      expect(_uriList(controller.state.upNext), <String>[
        localOk.uri,
        sub2.uri,
      ]);
    });

    test('a record from before owners were kept restores as it always did',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[sub1, localOk],
          currentIndex: 0,
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence =
          persistenceFor(store, controller, signedInAs: (_) => 'bob');

      await persistence.restore();

      expect(controller.state.currentTrack?.uri, sub1.uri);
    });

    test('songs nobody could say whose are wait', () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[sub1, localOk],
          currentIndex: 0,
          owners: <String, String>{},
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence =
          persistenceFor(store, controller, signedInAs: (_) => 'alice');

      await persistence.restore();

      expect(controller.state.currentTrack?.uri, localOk.uri);
      expect(controller.state.upNext, isEmpty);
    });

    test(
        "the other server's songs left out at one launch come back at the "
        'next one on their server', () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[localOk, plex7],
          currentIndex: 0,
          owners: <String, String>{'plex': 'server-a'},
        ),
      );
      final FakePlaybackController onServerB = FakePlaybackController();
      final PlaybackSessionPersistence first = persistenceFor(
        store,
        onServerB,
        signedInAs: (_) => 'server-b',
        queueOwnerOf: (_) async => 'server-b',
      );
      await first.restore();
      expect(onServerB.state.upNext, isEmpty);

      // Listening on through what was restored saves progress into the
      // whole record, still as server A's.
      onServerB.emit(onServerB.state.copyWith(
        position: const Duration(seconds: 40),
      ));
      await settle();
      await first.dispose();
      final PersistedPlaybackSession? saved = await store.load();
      expect(savedUris(saved), <String>[localOk.uri, plex7.uri]);
      expect(saved!.owners, <String, String>{'plex': 'server-a'});
      expect(saved.position, const Duration(seconds: 40));

      final FakePlaybackController onServerA = FakePlaybackController();
      final PlaybackSessionPersistence second =
          persistenceFor(store, onServerA, signedInAs: (_) => 'server-a');
      await second.restore();
      expect(_uriList(onServerA.state.upNext), <String>[plex7.uri]);
    });

    test('a save that waited on its owners never lands over a newer one',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      final Completer<String?> slow = Completer<String?>();
      int asks = 0;
      persistenceFor(
        store,
        controller,
        signedInAs: (_) => 'alice',
        queueOwnerOf: (_) => ++asks == 1 ? slow.future : Future.value('alice'),
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: sub1,
      ));
      await settle();
      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: sub2,
      ));
      await settle();
      expect((await store.load())!.current!.uri, sub2.uri);

      slow.complete('alice');
      await settle();

      expect((await store.load())!.current!.uri, sub2.uri);
    });

    test('a queue emptied while a save waited stays cleared', () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      final Completer<String?> slow = Completer<String?>();
      persistenceFor(
        store,
        controller,
        signedInAs: (_) => 'alice',
        queueOwnerOf: (_) => slow.future,
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: sub1,
      ));
      await settle();
      controller.emit(PlaybackState.idle);
      await settle();
      slow.complete('alice');
      await settle();

      expect(await store.load(), isNull);
    });

    test('the flush at shutdown asks nobody, and keeps whose they are',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      int asks = 0;
      final PlaybackSessionPersistence persistence = persistenceFor(
        store,
        controller,
        signedInAs: (_) => 'alice',
        queueOwnerOf: (_) async {
          // Past the first save there may be nobody left to ask.
          if (++asks > 1) throw StateError('shutting down');
          return 'alice';
        },
        positionSaveInterval: const Duration(hours: 1),
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: sub1,
        position: Duration(seconds: 1),
      ));
      await settle();
      controller.emit(const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: sub1,
        position: Duration(seconds: 2),
      ));
      await settle();
      await persistence.dispose();

      final PersistedPlaybackSession? saved = await store.load();
      expect(saved!.position, const Duration(seconds: 2));
      expect(saved.owners, <String, String>{'subsonic': 'alice'});
      expect(asks, 1);
    });
  });
}

List<String> _uriList(Iterable<Track> tracks) =>
    <String>[for (final Track t in tracks) t.uri];

/// A store that counts writes, so a test can assert how often the session
/// document is actually rewritten (the cost the debounce exists to bound).
class _CountingStore extends InMemoryPlaybackSessionStore {
  int saves = 0;

  @override
  Future<void> save(PersistedPlaybackSession session) async {
    saves++;
    await super.save(session);
  }
}

/// Local engine that throws from [restoreSession] so startup-safety can be
/// asserted without a real audio backend.
class _ThrowingRestoreController extends FakePlaybackController {
  @override
  Future<void> restoreSession({
    required List<Track> tracks,
    int startIndex = 0,
    Duration position = Duration.zero,
    bool shuffleEnabled = false,
    RepeatMode repeatMode = RepeatMode.off,
    List<Track>? originalOrder,
  }) async {
    throw StateError('simulated restore failure');
  }
}

/// An engine with just_audio's rules and a play clock: [advance] lets
/// playing time pass through the loaded source, which reports completed (with
/// `playing` still true) once that reaches its end, as just_audio and libmpv
/// do. Positions reach the controller's state through
/// `setPositionForTesting`, standing in for its periodic position flush.
class _EndingEngine extends Fake implements AudioPlayer {
  static const Duration length = Duration(minutes: 3);

  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();
  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;
  Duration _position = Duration.zero;

  /// Lets [elapsed] of playing time pass.
  void advance(Duration elapsed) {
    if (!_playing || _processing == ProcessingState.completed) return;
    _position += elapsed;
    if (_position >= length) {
      _position = length;
      _processing = ProcessingState.completed;
      _states.add(PlayerState(_playing, _processing));
    }
  }

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => _durations.stream;
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
    _position = Duration.zero;
    _processing = ProcessingState.ready;
    _durations.add(length);
    _states.add(PlayerState(_playing, _processing));
    return length;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _position = position ?? Duration.zero;
    _processing =
        _position >= length ? ProcessingState.completed : ProcessingState.ready;
    _states.add(PlayerState(_playing, _processing));
  }

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    _states.add(PlayerState(_playing, _processing));
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _states.add(PlayerState(_playing, _processing));
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _LocalResolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async =>
      ResolvedPlayable(Uri.file(track.uri), PlaybackSource.localFile);
}
