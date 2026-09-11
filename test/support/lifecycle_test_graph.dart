import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linthra/core/lifecycle/async_disposal_registry.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/remote_control_receiver.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'counting_audio_player.dart';
import 'fake_local_file_presence.dart';
import 'recording_remote_control_receiver.dart';

/// Opens [database]'s connection (drift opens lazily on the first query), so a
/// later "is it closed?" assertion is about a connection that was really open.
Future<void> openDatabase(LinthraDatabase database) async {
  await database.customSelect('SELECT 1').get();
}

/// Whether [database] still answers queries. After `ApplicationHandle.shutdown()`
/// has completed this must be false: the connection is closed, not closing.
Future<bool> isDatabaseOpen(LinthraDatabase database) async {
  try {
    await database.customSelect('SELECT 1').get();
    return true;
  } catch (_) {
    return false;
  }
}

/// The Linux startup graph `main()` wires, with every seam that would reach a
/// plugin, a socket, or the real filesystem replaced by a recording double.
///
/// Deliberately close to production: the container still builds the real
/// [ActivePlaybackController], [LinuxPlaybackController], remote-control
/// service/activator and Drift repositories, so a shutdown test exercises the
/// same teardown graph the app has.
List<Override> linuxLifecycleOverrides({
  required CountingAudioPlayer audioPlayer,
  RecordingRemoteControlReceiver? remoteControlReceiver,
  List<Override> extra = const <Override>[],
}) {
  return <Override>[
    hostPlatformProvider.overrideWithValue(HostPlatform.linux),
    linuxAudioPlayerProvider.overrideWithValue(audioPlayer),
    // These tests play tracks with made-up paths. The real presence check
    // would (correctly) refuse them as missing files, which is a different
    // suite's subject; here the interesting part is the lifecycle around a
    // track that plays.
    localFilePresenceProvider.overrideWithValue(FakeLocalFilePresence.all()),
    // The real database provider, over an in-memory executor: its close is the
    // asynchronous teardown the lifecycle has to wait for.
    linthraDatabaseExecutorProvider.overrideWithValue(NativeDatabase.memory()),
    driftMusicLibraryRepositoryOverride,
    playbackSessionStoreProvider
        .overrideWithValue(InMemoryPlaybackSessionStore()),
    if (remoteControlReceiver != null)
      // Same shape as the production provider (see
      // `remoteControlReceiverProvider`): the receiver is session-pinned and
      // its teardown is registered as asynchronous, so the lifecycle waits for
      // the transport to actually close. `overrideWithValue` would replace that
      // registration and quietly make the socket teardown untested.
      remoteControlReceiverProvider
          .overrideWith((Ref<RemoteControlReceiver> ref) {
        ref.onDisposeAsync(remoteControlReceiver.dispose);
        return remoteControlReceiver;
      }),
    ...extra,
  ];
}
