import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/linthra_app.dart';
import 'core/models/plex_session.dart';
import 'core/models/subsonic_session.dart';
import 'core/services/linthra_audio_handler.dart';
import 'core/sources/plex/plex_artwork.dart';
import 'core/sources/subsonic/subsonic_artwork.dart';
import 'data/repositories/default_provider_store_provider.dart';
import 'data/repositories/download_repository_provider.dart';
import 'data/repositories/favorites_repository_provider.dart';
import 'data/repositories/jellyfin_auto_sync_store_provider.dart';
import 'data/repositories/jellyfin_session_store_provider.dart';
import 'data/repositories/library_added_store_provider.dart';
import 'data/repositories/music_library_repository_provider.dart';
import 'data/repositories/play_history_repository_provider.dart';
import 'data/repositories/playback_preferences_provider.dart';
import 'data/repositories/playback_source_strategy_store_provider.dart';
import 'data/repositories/playlist_repository_provider.dart';
import 'data/repositories/plex_session_store_provider.dart';
import 'data/repositories/preferred_source_store_provider.dart';
import 'data/repositories/selected_music_folder_repository_provider.dart';
import 'data/repositories/subsonic_session_store_provider.dart';
import 'features/downloads/download_providers.dart';
import 'features/library/playback_candidates_provider.dart';
import 'features/player/cast/cast_providers.dart';
import 'features/player/favorites_providers.dart';
import 'features/player/lyrics_providers.dart';
import 'features/player/media_artwork_providers.dart';
import 'features/player/player_providers.dart';
import 'features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'features/settings/playback/normalize_volume_controller.dart';
import 'features/settings/plex/plex_settings_controller.dart';
import 'features/settings/subsonic/subsonic_settings_controller.dart';
import 'shared/widgets/artwork_image.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // One container backs the whole app so the *same* PlaybackController and
  // MusicLibraryRepository instances drive both the UI (through providers) and
  // the platform media session: Android Auto browses the real catalog and the
  // notification / lock screen reflect the real controller. The running app
  // persists its catalog to SQLite (Drift override) and its chosen folder,
  // offline-download set, and mobile-data preference via shared_preferences;
  // downloaded audio is written to an app-private directory on disk; and the
  // Jellyfin, Subsonic/Navidrome, and Plex session credentials are each
  // persisted in encrypted on-device storage. The remote downloader override
  // makes both Jellyfin and Subsonic tracks downloadable for offline use.
  // Tests keep the in-memory defaults unless they opt into these bindings.
  final container = ProviderContainer(
    overrides: [
      // The Drift catalog, wrapped so each scan/sync stamps newly-seen tracks
      // with a first-seen time for the "Recently added" smart mix.
      recordingDriftMusicLibraryRepositoryOverride,
      sharedPreferencesLibraryAddedStoreOverride,
      sharedPreferencesSelectedMusicFolderRepositoryOverride,
      // Persist which server the user most recently signed into, so the
      // active/default provider for de-duplicated songs survives a restart.
      sharedPreferencesPreferredSourceStoreOverride,
      // Persist the user's explicit default-source choice (Settings), which
      // pins a provider ahead of the most-recently-signed-in order.
      sharedPreferencesDefaultProviderStoreOverride,
      // Persist the chosen playback source strategy (prefer local/cache, highest
      // quality, lower data, balanced, or default).
      sharedPreferencesPlaybackSourceStrategyStoreOverride,
      // Make the playback source strategy cache-aware from the live offline set.
      offlineAvailableTrackIdsOverride,
      sharedPreferencesDownloadStoreOverride,
      sharedPreferencesDownloadPreferencesOverride,
      sharedPreferencesPlaybackPreferencesOverride,
      fileSystemOfflineFileStoreOverride,
      remoteTrackDownloaderOverride,
      // Let playback fall back to another copy of the same song when the
      // preferred source fails to resolve or start (the candidates come from the
      // unified library, in default-source-first order).
      playbackCandidateSourceOverride,
      currentlyPlayingTrackIdOverride,
      // Drive the now-playing indicator on track rows from live playback (the
      // current logical track + play/pause), so every list surface marks the
      // playing song. Inert by default in tests.
      nowPlayingOverride,
      secureJellyfinSessionStoreOverride,
      // Remember which Jellyfin account has had its first auto-sync, so a
      // reconnect after a restart doesn't trigger an unsolicited full re-sync.
      sharedPreferencesJellyfinAutoSyncStoreOverride,
      secureSubsonicSessionStoreOverride,
      securePlexSessionStoreOverride,
      sharedPreferencesFavoritesStoreOverride,
      jellyfinFavoritesOverride,
      sharedPreferencesPlaylistStoreOverride,
      jellyfinPlaylistSyncOverride,
      // Persist on-device play history (counts + last-played) for the
      // "Recently played" / "Most played" / "Never played" smart mixes.
      sharedPreferencesPlayHistoryStoreOverride,
      // Lyrics from whichever source owns the track: a signed-in Jellyfin or
      // Subsonic/Navidrome server, or a sidecar .lrc/.txt next to a local file.
      lyricsServiceOverride,
      // Real Chromecast backend (Android/iOS only); see cast_providers.dart.
      chromecastCastServiceOverride,
    ],
  );

  // Attaching the session is best-effort: on a platform without the native
  // audio_service setup it returns null and basic playback still works. The
  // handler mirrors the controller and outlives this scope with the container.
  // Passing the playlist + favourites + downloads repositories lets Android Auto
  // browse Playlists/Favorites/Offline (when the user has any) alongside
  // Songs/Albums/Artists/Queue — all read straight from the persisted stores, so
  // the car tree is answerable even before any phone screen is opened.
  //
  // The media-session artwork cache lets the now-playing card show a
  // credential-free source's cover (Subsonic) as a safe local file: — the
  // handler reads it synchronously, never a credentialed getCoverArt URL. The
  // covers are fetched (server-downscaled) and cached ahead of time, off the
  // playback path, by the prewarm service started below.
  await connectMediaSession(
    container.read(playbackControllerProvider),
    container.read(musicLibraryRepositoryProvider),
    playlists: container.read(playlistRepositoryProvider),
    favorites: container.read(favoritesRepositoryProvider),
    downloads: container.read(downloadRepositoryProvider),
    artwork: container.read(mediaArtworkCacheProvider),
  );

  // Warm the now-playing + look-ahead Subsonic covers into the media-session
  // artwork cache as playback advances, so each cover is cached before its track
  // reaches the now-playing card (beating a head unit's metadata snapshot).
  // Off the playback path and best-effort, like the stream preloader below;
  // instantiating it wires the listener.
  container.read(mediaArtworkPrewarmServiceProvider);

  // Start smart pre-cache: as playback advances it warms the next queued tracks
  // into the offline cache (under the same limit, honouring "Allow mobile data"
  // and the user's smart-pre-cache on/off + count, and staying calm under
  // repeat-one).
  // Instantiating it wires the listener; it has no value the UI reads.
  container.read(smartPrecacheServiceProvider);

  // Start remote prebuffer: as playback advances it warms the current and next
  // remote stream URLs in memory so a skip starts faster — without touching the
  // offline cache or marking anything downloaded. Side-effect-only, like smart
  // pre-cache.
  container.read(remotePrebufferServiceProvider);

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

  // Likewise warm any persisted Plex session so plex: tracks can resolve and
  // plex-thumb: covers can render from the first frame. Best-effort and
  // secret-free: a missing/corrupt record loads as "not connected" and never
  // blocks launch.
  try {
    await container
        .read(plexSettingsControllerProvider.notifier)
        .ensureLoaded();
  } catch (_) {
    // Ignore: the user can still connect in Settings.
  }

  // Teach the shared artwork seam how to turn a credential-free cover
  // reference (subsonic-cover:<id> or plex-thumb:<path>, the only artwork the
  // catalog persists for those providers) into an authenticated cover URL,
  // weaving the live session's credential in at render time — exactly how
  // stream URLs are minted on demand, so the credential never reaches the
  // catalog. Each resolver owns one scheme and returns null for the rest, so
  // they chain safely. Sessions are read live, so signing in/out is picked up
  // without a rebuild; a signed-out provider's reference stays unresolved (the
  // row keeps its placeholder) and anything else (Jellyfin and local covers)
  // loads directly.
  // Secret-free: only the resolved NetworkImage URL is built, never logged.
  installArtworkReferenceResolver((Uri reference) {
    final SubsonicSession? subsonicSession =
        container.read(subsonicSettingsControllerProvider.notifier).session;
    if (subsonicSession != null) {
      final Uri? resolved = SubsonicArtwork.resolve(reference, subsonicSession);
      if (resolved != null) return resolved;
    }
    final PlexSession? plexSession =
        container.read(plexMusicSourceProvider)?.session;
    if (plexSession != null) {
      final Uri? resolved = PlexArtwork.resolve(reference, plexSession);
      if (resolved != null) return resolved;
    }
    return null;
  });

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
