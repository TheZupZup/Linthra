import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/halcyon_app.dart';
import 'core/services/just_audio_playback_controller.dart';
import 'core/services/halcyon_audio_handler.dart';
import 'data/repositories/download_repository_provider.dart';
import 'data/repositories/music_library_repository_provider.dart';
import 'data/repositories/selected_music_folder_repository_provider.dart';
import 'features/player/player_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Build the playback controller up front so the *same* instance backs both
  // the UI (via playbackControllerProvider) and the platform media session
  // (via audio_service). Attaching the session is best-effort: on a platform
  // without the native setup it returns null and basic playback still works.
  final controller = JustAudioPlaybackController();
  final handler = await connectMediaSession(controller);

  // ProviderScope hosts all Riverpod state for the app. The running app
  // persists its catalog to SQLite via the Drift override and the chosen music
  // folder, offline-download set, and Wi-Fi-only preference via
  // shared_preferences; tests keep the in-memory defaults unless they opt into
  // these bindings.
  runApp(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWith((ref) {
          ref.onDispose(() async {
            await handler?.dispose();
            await controller.dispose();
          });
          return controller;
        }),
        driftMusicLibraryRepositoryOverride,
        sharedPreferencesSelectedMusicFolderRepositoryOverride,
        sharedPreferencesDownloadStoreOverride,
        sharedPreferencesDownloadPreferencesOverride,
      ],
      child: const HalcyonApp(),
    ),
  );
}
