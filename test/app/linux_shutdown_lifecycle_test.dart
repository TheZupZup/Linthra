import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/lifecycle/async_disposal_registry.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/playback_session_store.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/services/remote_control_receiver.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/playback/normalize_volume_controller.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';
import 'package:path/path.dart' as p;

import '../support/counting_audio_player.dart';
import '../support/lifecycle_test_graph.dart';
import '../support/recording_media_session.dart';
import '../support/recording_remote_control_receiver.dart';

/// Builds the Linux provider graph the way `main()` wires it, without
/// `runApp`, so shutdown cycles can be exercised deterministically.
///
/// The media session is a test double for the same reason the audio player is:
/// bootstrap's default binding reads the real host, so on a Linux machine this
/// would attach over the real MPRIS session bus. A shutdown suite has no
/// business opening one, and how long that takes is the machine's answer, not
/// a deterministic one.
Future<ApplicationHandle> _bootstrap(
  ProviderContainer container, {
  bool installPersistentArtworkCache = false,
  Directory? artworkCacheDirectory,
  RecordingMediaSessionBinding? mediaSessionBinding,
}) {
  return bootstrapApplication(
    container,
    installPersistentArtworkCache: installPersistentArtworkCache,
    artworkCacheDirectory: artworkCacheDirectory,
    mediaSessionBinding: mediaSessionBinding ??
        RecordingMediaSessionBinding(session: RecordingMediaSession()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Linux shutdown lifecycle', () {
    test('initialize -> play -> stop -> shutdown -> initialize again',
        () async {
      final CountingAudioPlayer firstPlayer = CountingAudioPlayer();
      final ProviderContainer firstContainer = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: firstPlayer),
      );

      final ApplicationHandle firstHandle = await _bootstrap(firstContainer);
      final LinthraDatabase firstDb =
          firstContainer.read(linthraDatabaseProvider);
      await openDatabase(firstDb);

      await firstContainer.read(playbackControllerProvider).playTrack(
            const Track(id: 'a', title: 'Song', uri: '/music/a.mp3'),
          );
      expect(
        firstContainer.read(playbackControllerProvider).state.status,
        PlaybackStatus.playing,
      );

      await firstContainer.read(playbackControllerProvider).stop();
      await firstHandle.shutdown();

      expect(firstPlayer.disposeCount, 1);
      expect(firstPlayer.disposeFinished, isTrue);
      expect(firstPlayer.stopCount, greaterThanOrEqualTo(1));
      expect(await isDatabaseOpen(firstDb), isFalse);

      final CountingAudioPlayer secondPlayer = CountingAudioPlayer();
      final ProviderContainer secondContainer = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: secondPlayer),
      );

      final ApplicationHandle secondHandle = await _bootstrap(secondContainer);

      expect(
        secondContainer.read(localPlaybackControllerProvider),
        isA<LinuxPlaybackController>(),
      );
      // Nothing the first container owned reaches the second one: its database
      // opens and answers queries even though the first one's is closed.
      await openDatabase(secondContainer.read(linthraDatabaseProvider));
      expect(
        await isDatabaseOpen(secondContainer.read(linthraDatabaseProvider)),
        isTrue,
      );
      await secondContainer.read(playbackControllerProvider).playTrack(
            const Track(id: 'b', title: 'Again', uri: '/music/b.mp3'),
          );
      expect(
        secondContainer.read(playbackControllerProvider).state.status,
        PlaybackStatus.playing,
      );
      expect(firstPlayer.playCount, 1);

      await secondHandle.shutdown();
      expect(secondPlayer.disposeCount, 1);
    });

    test('initialize -> shutdown without playback', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: player),
      );

      final ApplicationHandle handle = await _bootstrap(container);
      await handle.shutdown();

      expect(player.disposeCount, 1);
      expect(player.playCount, 0);
    });

    test('shutdown gives the media session back', () async {
      final RecordingMediaSession session = RecordingMediaSession();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );

      final ApplicationHandle handle = await _bootstrap(
        container,
        mediaSessionBinding: RecordingMediaSessionBinding(session: session),
      );
      expect(session.detachCount, 0,
          reason: 'the session is live for as long as the app is');

      await handle.shutdown();

      // On Linux that detach is what releases org.mpris.MediaPlayer2.linthra:
      // a player that exits still holding it leaves a ghost in every shell
      // that was listening.
      expect(session.detachCount, 1);
    });

    test('a host with no media session still shuts down cleanly', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: player),
      );
      final RecordingMediaSessionBinding binding =
          RecordingMediaSessionBinding();

      final ApplicationHandle handle =
          await _bootstrap(container, mediaSessionBinding: binding);
      await handle.shutdown();

      expect(binding.attachCount, 1);
      expect(player.disposeCount, 1);
    });

    test('shutdown stops playback that is still running', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: player),
      );

      final ApplicationHandle handle = await _bootstrap(container);
      await container.read(playbackControllerProvider).playTrack(
            const Track(id: 'a', title: 'Song', uri: '/music/a.mp3'),
          );

      await handle.shutdown();

      expect(player.stopCount, greaterThanOrEqualTo(1));
      expect(player.disposeCount, 1);
    });

    test(
        'shutdown does not complete until the audio engine has finished '
        'tearing down', () async {
      final Completer<void> gate = Completer<void>();
      final CountingAudioPlayer player = CountingAudioPlayer(disposeGate: gate);
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: player),
      );

      final ApplicationHandle handle = await _bootstrap(container);

      bool completed = false;
      final Future<void> shutdown = handle.shutdown().then((_) {
        completed = true;
      });

      await pumpEventQueue();
      expect(player.disposeStarted, isTrue);
      expect(player.disposeFinished, isFalse);
      expect(completed, isFalse,
          reason: 'shutdown() must still be waiting on the engine');

      gate.complete();
      await shutdown;

      expect(completed, isTrue);
      expect(player.disposeFinished, isTrue);
    });

    test(
        'shutdown does not complete until container teardown started by '
        'ProviderContainer.dispose has finished', () async {
      final Completer<void> gate = Completer<void>();
      final RecordingRemoteControlReceiver receiver =
          RecordingRemoteControlReceiver(disposeGate: gate);
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(
          audioPlayer: CountingAudioPlayer(),
          remoteControlReceiver: receiver,
        ),
      );

      final AsyncDisposalRegistry registry =
          container.read(asyncDisposalRegistryProvider);
      final ApplicationHandle handle = await _bootstrap(container);

      bool completed = false;
      final Future<void> shutdown = handle.shutdown().then((_) {
        completed = true;
      });

      await pumpEventQueue();
      expect(receiver.disposeStarted, isTrue,
          reason: 'the container must have started the receiver teardown');
      expect(receiver.commandsClosed, isFalse);
      expect(completed, isFalse,
          reason: 'shutdown() must still be waiting on the control socket');
      expect(registry.isSettled, isFalse);

      gate.complete();
      await shutdown;

      expect(receiver.disposeFinished, isTrue);
      expect(receiver.commandsClosed, isTrue,
          reason: 'the control socket is gone, not going');
      expect(receiver.disposeCount, 1, reason: 'no double dispose');
      expect(registry.isSettled, isTrue);
      expect(registry.failures, isEmpty);
    });

    test('the real remote-control receiver is torn down by the container',
        () async {
      // No receiver override here: this is the production provider graph, so
      // it also proves `remoteControlReceiverProvider` really does register its
      // teardown as asynchronous work the lifecycle waits for.
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );
      final ApplicationHandle handle = await _bootstrap(container);

      final RemoteControlReceiver receiver =
          container.read(remoteControlReceiverProvider);
      bool commandsClosed = false;
      final StreamSubscription<RemoteCommand> subscription =
          receiver.commands.listen(null, onDone: () => commandsClosed = true);
      addTearDown(subscription.cancel);

      await handle.shutdown();

      expect(commandsClosed, isTrue,
          reason: 'the control-command stream is closed, not closing');
    });

    test('the database is closed — not closing — when shutdown completes',
        () async {
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );

      final ApplicationHandle handle = await _bootstrap(container);
      final LinthraDatabase database = container.read(linthraDatabaseProvider);
      await openDatabase(database);
      expect(await isDatabaseOpen(database), isTrue);

      await handle.shutdown();

      expect(await isDatabaseOpen(database), isFalse);
    });

    test('global artwork hooks are cleared', () async {
      final Directory cacheDirectory =
          await Directory.systemTemp.createTemp('linthra_artwork_cache');
      addTearDown(() => cacheDirectory.delete(recursive: true));

      // Seed a hit so the installed disk cache is observable through the one
      // seam every artwork render goes through.
      final Uri cover = Uri.parse('https://covers.test/a.png');
      final String hashed =
          sha256.convert(utf8.encode(cover.toString())).toString();
      File(p.join(cacheDirectory.path, '$hashed.img'))
          .writeAsBytesSync(<int>[1, 2, 3]);

      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );
      final ApplicationHandle handle = await _bootstrap(
        container,
        installPersistentArtworkCache: true,
        artworkCacheDirectory: cacheDirectory,
      );

      expect(artworkImageProvider(cover), isA<FileImage>());

      await handle.shutdown();

      // The disk-cache hook is gone: the same render is a plain network load.
      expect(artworkImageProvider(cover), isA<NetworkImage>());
      // And so is the resolver hook — which closed over the now-disposed
      // container, so a leaked one would throw here instead of resolving.
      expect(
        artworkImageProvider(Uri.parse('subsonic-cover:1')),
        isA<NetworkImage>().having(
          (NetworkImage image) => image.url,
          'url',
          'subsonic-cover:1',
        ),
      );
    });

    test('an owned subscription stops receiving updates after shutdown',
        () async {
      // The observed container is a second, independent one: the handle's own
      // container is disposed by shutdown, which would mask whether the
      // subscription itself was closed.
      final ProviderContainer observed = ProviderContainer();
      addTearDown(observed.dispose);
      final StateProvider<int> counter = StateProvider<int>((ref) => 0);
      final List<int> seen = <int>[];

      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );
      final ApplicationHandle handle = await _bootstrap(container);
      handle.ownSubscription(
        observed.listen<int>(counter, (_, int next) => seen.add(next)),
      );

      observed.read(counter.notifier).state = 1;
      expect(seen, <int>[1]);

      await handle.shutdown();

      observed.read(counter.notifier).state = 2;
      expect(seen, <int>[1], reason: 'the subscription is closed');
    });

    test('shutdown waits for best-effort startup work it owns', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );
      final ApplicationHandle handle = await _bootstrap(container);

      final Completer<void> pending = Completer<void>();
      handle.ownPendingWork(pending.future);

      bool completed = false;
      final Future<void> shutdown =
          handle.shutdown().then((_) => completed = true);

      await pumpEventQueue();
      expect(completed, isFalse,
          reason: 'startup work still writing must not be left running');

      pending.complete();
      await shutdown;
      expect(completed, isTrue);
    });

    test(
        'teardown steps run newest-first and a failing step does not strand '
        'the others', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );
      final ApplicationHandle handle = await _bootstrap(container);

      final List<String> order = <String>[];
      handle.own(() => order.add('first'));
      handle.own(() async => throw StateError('teardown blew up'));
      handle.own(() => order.add('last'));

      await handle.shutdown();

      expect(order, <String>['last', 'first']);
    });

    test('repeated and concurrent shutdown is safe', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final RecordingRemoteControlReceiver receiver =
          RecordingRemoteControlReceiver();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(
          audioPlayer: player,
          remoteControlReceiver: receiver,
        ),
      );

      final ApplicationHandle handle = await _bootstrap(container);

      await Future.wait<void>(<Future<void>>[
        handle.shutdown(),
        handle.shutdown(),
      ]);
      await handle.shutdown();

      expect(player.disposeCount, 1);
      expect(receiver.disposeCount, 1);
    });

    test('partial startup -> shutdown', () async {
      final CountingAudioPlayer player = CountingAudioPlayer();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: player),
      );

      // Read only the early startup surface — not the full bootstrap graph.
      container.read(musicLibraryRepositoryProvider);
      container.read(playbackControllerProvider);

      final ApplicationHandle handle = ApplicationHandle(
        container: container,
        normalizeVolumeSubscription: container.listen(
          normalizeVolumeControllerProvider,
          (_, __) {},
        ),
      );

      await handle.shutdown();

      expect(player.disposeCount, 1);
    });

    test('database can be recreated after the first container is disposed',
        () async {
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );

      final ApplicationHandle handle = await _bootstrap(container);
      await handle.shutdown();

      final ProviderContainer freshContainer = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
      );
      addTearDown(freshContainer.dispose);

      expect(
        freshContainer.read(musicLibraryRepositoryProvider),
        isA<DriftMusicLibraryRepository>(),
      );
      await openDatabase(freshContainer.read(linthraDatabaseProvider));
      expect(
        await isDatabaseOpen(freshContainer.read(linthraDatabaseProvider)),
        isTrue,
      );
    });

    // Quitting stops the speakers before anything else is torn down, and the
    // stop reads as the queue being stopped at its start. The session saved
    // for the next launch must still say where the listener left off.
    group('the session saved on quit keeps where playback was', () {
      const Track song = Track(id: 'a', title: 'Song', uri: '/music/a.mp3');
      const Duration leftOff = Duration(minutes: 1, seconds: 30);

      Future<PlaybackSessionStore> playThenQuit({required bool pause}) async {
        final ProviderContainer container = ProviderContainer(
          overrides:
              linuxLifecycleOverrides(audioPlayer: CountingAudioPlayer()),
        );
        final PlaybackSessionStore store =
            container.read(playbackSessionStoreProvider);
        final ApplicationHandle handle = await _bootstrap(container);
        final LinuxPlaybackController engine = container
            .read(localPlaybackControllerProvider) as LinuxPlaybackController;

        await container.read(playbackControllerProvider).playTrack(song);
        engine.setPositionForTesting(leftOff);
        if (pause) await container.read(playbackControllerProvider).pause();
        await pumpEventQueue();

        await handle.shutdown();
        return store;
      }

      test('paused, then quit', () async {
        final PersistedPlaybackSession? saved =
            await (await playThenQuit(pause: true)).load();

        expect(saved?.current?.uri, song.uri);
        expect(saved?.position, leftOff);
      });

      test('quit while playing', () async {
        final PersistedPlaybackSession? saved =
            await (await playThenQuit(pause: false)).load();

        expect(saved?.current?.uri, song.uri);
        expect(saved?.position, leftOff);
      });
    });
  });
}
