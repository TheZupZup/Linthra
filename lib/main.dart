import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/linthra_app.dart';
import 'core/services/linthra_audio_handler.dart';
import 'data/repositories/download_repository_provider.dart';
import 'data/repositories/favorites_repository_provider.dart';
import 'data/repositories/jellyfin_session_store_provider.dart';
import 'data/repositories/music_library_repository_provider.dart';
import 'data/repositories/selected_music_folder_repository_provider.dart';
import 'data/repositories/subsonic_session_store_provider.dart';
import 'features/downloads/download_providers.dart';
import 'features/player/cast/cast_providers.dart';
import 'features/player/favorites_providers.dart';
import 'features/player/lyrics_providers.dart';
import 'features/player/player_providers.dart';
import 'features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'features/settings/subsonic/subsonic_settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // One container backs the whole app so the *same* PlaybackController and
  // MusicLibraryRepository instances drive both the UI (through providers) and
  // the platform media session: Android Auto browses the real catalog and the
  // notification / lock screen reflect the real controller. The running app
  // persists its catalog to SQLite (Drift override) and its chosen folder,
  // offline-download set, and Wi-Fi-only preference via shared_preferences;
  // downloaded audio is written to an app-private directory on disk; and the
  // Jellyfin and Subsonic/Navidrome session credentials are each persisted in
  // encrypted on-device storage. The remote downloader override makes both
  // Jellyfin and Subsonic tracks downloadable for offline use. Tests keep the
  // in-memory defaults unless they opt into these bindings.
  final container = ProviderContainer(
    overrides: [
      driftMusicLibraryRepositoryOverride,
      sharedPreferencesSelectedMusicFolderRepositoryOverride,
      sharedPreferencesDownloadStoreOverride,
      sharedPreferencesDownloadPreferencesOverride,
      fileSystemOfflineFileStoreOverride,
      remoteTrackDownloaderOverride,
      currentlyPlayingTrackIdOverride,
      secureJellyfinSessionStoreOverride,
      secureSubsonicSessionStoreOverride,
      sharedPreferencesFavoritesStoreOverride,
      jellyfinFavoritesOverride,
      jellyfinLyricsOverride,
      // Real Chromecast backend (Android/iOS only); see cast_providers.dart.
      chromecastCastServiceOverride,
    ],
  );

  // Attaching the session is best-effort: on a platform without the native
  // audio_service setup it returns null and basic playback still works. The
  // handler mirrors the controller and outlives this scope with the container.
  await connectMediaSession(
    container.read(playbackControllerProvider),
    container.read(musicLibraryRepositoryProvider),
  );

  // Start smart pre-cache: as playback advances it warms the next queued tracks
  // into the offline cache (under the same limit, honouring "Wi-Fi only" and the
  // user's smart-pre-cache on/off + count, and staying calm under repeat-one).
  // Instantiating it wires the listener; it has no value the UI reads.
  container.read(smartPrecacheServiceProvider);

  // Warm the persisted Jellyfin session before the first frame so a synced
  // remote track can stream on the first tap — without it, playback would race
  // the background session load and could fail with "not signed in", making
  // streaming look like it required downloading first. Best-effort: the loader
  // already swallows storage errors, but guard here too so a failure never
  // blocks launch. No token is read into the UI or logged.
  try {
    await container
        .read(jellyfinSettingsControllerProvider.notifier)
        .ensureLoaded();
  } catch (_) {
    // Ignore: the user can still connect in Settings.
  }

  // Likewise warm any persisted Subsonic/Navidrome session so a synced Subsonic
  // track can stream on the first tap. Best-effort and secret-free.
  try {
    await container
        .read(subsonicSettingsControllerProvider.notifier)
        .ensureLoaded();
  } catch (_) {
    // Ignore: the user can still connect in Settings.
  }

  // With the session loaded, pull the user's Jellyfin favourites so the heart
  // reflects the server from the first frame. Best-effort and offline-tolerant:
  // the repository swallows failures and keeps any locally stored favourites.
  unawaited(container.read(favoritesRepositoryProvider).refreshFromRemote());

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LinthraApp(),
    ),
  );
}
