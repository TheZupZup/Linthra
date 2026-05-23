import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/sonara_app.dart';
import 'data/repositories/download_repository_provider.dart';
import 'data/repositories/music_library_repository_provider.dart';
import 'data/repositories/selected_music_folder_repository_provider.dart';

void main() {
  // ProviderScope hosts all Riverpod state for the app. The running app
  // persists its catalog to SQLite via the Drift override and the chosen music
  // folder, offline-download set, and Wi-Fi-only preference via
  // shared_preferences; tests keep the in-memory defaults unless they opt into
  // these bindings.
  runApp(
    ProviderScope(
      overrides: [
        driftMusicLibraryRepositoryOverride,
        sharedPreferencesSelectedMusicFolderRepositoryOverride,
        sharedPreferencesDownloadStoreOverride,
        sharedPreferencesDownloadPreferencesOverride,
      ],
      child: const SonaraApp(),
    ),
  );
}
