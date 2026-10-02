import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
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
        isRemoteProviderAvailable: (MusicProvider p) =>
            !identical(p, MusicProviders.jellyfin),
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
          isRemoteProviderAvailable: (_) => false,
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
}

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
