import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/linthra_app.dart';
import 'core/services/linthra_audio_handler.dart';
import 'data/repositories/download_repository_provider.dart';
import 'data/repositories/jellyfin_session_store_provider.dart';
import 'data/repositories/music_library_repository_provider.dart';
import 'data/repositories/selected_music_folder_repository_provider.dart';
import 'features/player/player_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // One container backs the whole app so the *same* PlaybackController and
  // MusicLibraryRepository instances drive both the UI (through providers) and
  // the platform media session: Android Auto browses the real catalog and the
  // notification / lock screen reflect the real controller. The running app
  // persists its catalog to SQLite (Drift override) and its chosen folder,
  // offline-download set, and Wi-Fi-only preference via shared_preferences;
  // the Jellyfin session token is persisted in encrypted on-device storage.
  // Tests keep the in-memory defaults unless they opt into these bindings.
  final container = ProviderContainer(
    overrides: [
      driftMusicLibraryRepositoryOverride,
      sharedPreferencesSelectedMusicFolderRepositoryOverride,
      sharedPreferencesDownloadStoreOverride,
      sharedPreferencesDownloadPreferencesOverride,
      secureJellyfinSessionStoreOverride,
    ],
  );

  // Attaching the session is best-effort: on a platform without the native
  // audio_service setup it returns null and basic playback still works. The
  // handler mirrors the controller and outlives this scope with the container.
  await connectMediaSession(
    container.read(playbackControllerProvider),
    container.read(musicLibraryRepositoryProvider),
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LinthraApp(),
    ),
  );
}
