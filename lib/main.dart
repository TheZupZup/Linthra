import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/linthra_app.dart';
import 'core/services/linthra_audio_handler.dart';
import 'data/repositories/download_repository_provider.dart';
import 'data/repositories/favorites_repository_provider.dart';
import 'data/repositories/jellyfin_auto_sync_store_provider.dart';
import 'data/repositories/jellyfin_session_store_provider.dart';
import 'data/repositories/library_added_store_provider.dart';
import 'data/repositories/music_library_repository_provider.dart';
import 'data/repositories/play_history_repository_provider.dart';
import 'data/repositories/playback_preferences_provider.dart';
import 'data/repositories/playlist_repository_provider.dart';
import 'data/repositories/selected_music_folder_repository_provider.dart';
import 'data/repositories/subsonic_session_store_provider.dart';
import 'features/downloads/download_providers.dart';
import 'features/player/cast/cast_providers.dart';
import 'features/player/favorites_providers.dart';
import 'features/player/lyrics_providers.dart';
import 'features/player/player_providers.dart';
import 'features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'features/settings/playback/normalize_volume_controller.dart';
import 'features/settings/subsonic/subsonic_settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // One container backs the whole app so the *same* PlaybackController and
  // MusicLibraryRepository instances drive both the UI (through providers) and
  // the platform media session: Android Auto browses the real catalog and the
  // notification / lock screen reflect the real controller. The running app
  // persists its catalog to SQLite (Drift override) and its chosen folder,
  // offline-download set, and mobile-data preference via shared_preferences;
  // downloaded audio is written to an app-private directory on disk; and the
  // Jellyfin and Subsonic/Navidrome session credentials are each persisted in
  // encrypted on-device storage. The remote downloader override makes both
  // Jellyfin and Subsonic tracks downloadable for offline use. Tests keep the
  // in-memory defaults unless they opt into these bindings.
  final container = ProviderContainer(
    overrides: [
      // The Drift catalog, wrapped so each scan/sync stamps newly-seen tracks
      // with a first-seen time for the "Recently added" smart mix.
      recordingDriftMusicLibraryRepositoryOverride,
      sharedPreferencesLibraryAddedStoreOverride,
      sharedPreferencesSelectedMusicFolderRepositoryOverride,
      sharedPreferencesDownloadStoreOverride,
      sharedPreferencesDownloadPreferencesOverride,
      sharedPreferencesPlaybackPreferencesOverride,
      fileSystemOfflineFileStoreOverride,
      remoteTrackDownloaderOverride,
      currentlyPlayingTrackIdOverride,
      secureJellyfinSessionStoreOverride,
      // Remember which Jellyfin account has had its first auto-sync, so a
      // reconnect after a restart doesn't trigger an unsolicited full re-sync.
      sharedPreferencesJellyfinAutoSyncStoreOverride,
      secureSubsonicSessionStoreOverride,
      sharedPreferencesFavoritesStoreOverride,
      jellyfinFavoritesOverride,
      sharedPreferencesPlaylistStoreOverride,
      jellyfinPlaylistSyncOverride,
      // Persist on-device play history (counts + last-played) for the
      // "Recently played" / "Most played" / "Never played" smart mixes.
      sharedPreferencesPlayHistoryStoreOverride,
      jellyfinLyricsOverride,
      // Real Chromecast backend (Android/iOS only); see cast_providers.dart.
      chromecastCastServiceOverride,
    ],
  );

  // Attaching the session is best-effort: on a platform without the native
  // audio_service setup it returns null and basic playback still works. The
  // handler mirrors the controller and outlives this scope with the container.
  // Passing the playlist + favourites repositories lets Android Auto browse
  // Playlists/Favorites (when the user has any) alongside Library/Queue — all
  // read straight from the persisted stores, so the car tree is answerable even
  // before any phone screen is opened.
  await connectMediaSession(
    container.read(playbackControllerProvider),
    container.read(musicLibraryRepositoryProvider),
    playlists: container.read(playlistRepositoryProvider),
    favorites: container.read(favoritesRepositoryProvider),
  );

  // Start smart pre-cache: as playback advances it warms the next queued tracks
  // into the offline cache (under the same limit, honouring "Allow mobile data"
  // and the user's smart-pre-cache on/off + count, and staying calm under
  // repeat-one).
  // Instantiating it wires the listener; it has no value the UI reads.
  container.read(smartPrecacheServiceProvider);

  // Start stream preload: as playback advances it warms the next remote track's
  // stream URL in memory so a skip starts faster — without touching the offline
  // cache or marking anything downloaded. Side-effect-only, like smart pre-cache.
  container.read(streamPreloadServiceProvider);

  // Mirror the user's "Normalize volume" choice onto the local audio engine,
  // seeding the persisted value now and pushing every later toggle. The engine
  // applies the clip-safe ReplayGain attenuation; with the choice off (the
  // default) audio plays untouched.
  container.listen<AsyncValue<bool>>(
    normalizeVolumeControllerProvider,
    (_, next) {
      container
          .read(localPlaybackControllerProvider)
          .setVolumeNormalizationEnabled(next.valueOrNull ?? false);
    },
    fireImmediately: true,
  );

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

  // Likewise import the user's Jellyfin playlists so synced playlists appear on
  // the Playlists tab from the first frame. Best-effort and offline-tolerant.
  unawaited(container.read(playlistRepositoryProvider).refreshFromRemote());

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LinthraApp(),
    ),
  );
}
