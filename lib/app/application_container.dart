import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/theme_mode_preference.dart';
import '../core/platform/host_platform.dart';
import '../data/repositories/app_icon_variant_store_provider.dart';
import '../data/repositories/audio_output_device_service_provider.dart';
import '../data/repositories/audiobookshelf_session_store_provider.dart';
import '../data/repositories/default_provider_store_provider.dart';
import '../data/repositories/desktop_window_controller_provider.dart';
import '../data/repositories/desktop_window_preferences_provider.dart';
import '../data/repositories/download_repository_provider.dart';
import '../data/repositories/favorites_repository_provider.dart';
import '../data/repositories/jellyfin_auto_sync_store_provider.dart';
import '../data/repositories/jellyfin_session_store_provider.dart';
import '../data/repositories/launcher_icon_service_provider.dart';
import '../data/repositories/library_added_store_provider.dart';
import '../data/repositories/library_tab_store_provider.dart';
import '../data/repositories/music_library_repository_provider.dart';
import '../data/repositories/play_history_repository_provider.dart';
import '../data/repositories/playback_preferences_provider.dart';
import '../data/repositories/playback_session_store_provider.dart';
import '../data/repositories/playback_source_strategy_store_provider.dart';
import '../data/repositories/playlist_repository_provider.dart';
import '../data/repositories/plex_session_store_provider.dart';
import '../data/repositories/plex_sync_cache_store_provider.dart';
import '../data/repositories/preferred_source_store_provider.dart';
import '../data/repositories/selected_music_folder_repository_provider.dart';
import '../data/repositories/share_service_provider.dart';
import '../data/repositories/subsonic_auto_sync_store_provider.dart';
import '../data/repositories/subsonic_session_store_provider.dart';
import '../data/repositories/theme_mode_store_provider.dart';
import '../features/appearance/theme_mode_controller.dart';
import '../features/downloads/download_providers.dart';
import '../features/library/playback_candidates_provider.dart';
import '../features/player/cast/cast_providers.dart';
import '../features/player/favorites_providers.dart';
import '../features/player/lyrics_providers.dart';
import '../features/player/player_providers.dart';
import '../features/settings/jellyfin/jellyfin_availability_controller.dart';

/// Production [ProviderContainer] overrides — the same list `main()` applies
/// before bootstrap. Tests build their own override list and may include these
/// selectively; they are extracted so the real startup graph can be wired
/// without calling `runApp`.
List<Override> productionApplicationOverrides({
  required ThemeModePreference storedThemeMode,
  HostPlatform? host,
}) {
  final HostPlatform resolvedHost = host ?? HostPlatform.current;
  return <Override>[
    recordingDriftMusicLibraryRepositoryOverride,
    sharedPreferencesLibraryAddedStoreOverride,
    sharedPreferencesLibraryTabStoreOverride,
    sharedPreferencesSelectedMusicFolderRepositoryOverride,
    sharedPreferencesPreferredSourceStoreOverride,
    sharedPreferencesDefaultProviderStoreOverride,
    sharedPreferencesPlaybackSourceStrategyStoreOverride,
    offlineAvailableTrackKeysOverride,
    sharedPreferencesDownloadStoreOverride,
    sharedPreferencesDownloadPreferencesOverride,
    sharedPreferencesPlaybackPreferencesOverride,
    sharedPreferencesDesktopWindowPreferencesOverride,
    if (resolvedHost == HostPlatform.linux) ...<Override>[
      sharedPreferencesPlaybackSessionStoreOverride,
      // The window-lifecycle channel is Linthra's own GTK runner (#401), so
      // only the Linux build ever opens it. Everywhere else the app keeps the
      // no-op window controller and closing a window means whatever the host
      // already made it mean.
      linuxDesktopWindowControllerOverride,
    ],
    fileSystemOfflineFileStoreOverride,
    remoteTrackDownloaderOverride,
    playbackCandidateSourceOverride,
    currentlyPlayingTrackOverride,
    nowPlayingOverride,
    secureJellyfinSessionStoreOverride,
    jellyfinAvailabilityPollOverride,
    sharedPreferencesJellyfinAutoSyncStoreOverride,
    secureSubsonicSessionStoreOverride,
    sharedPreferencesSubsonicAutoSyncStoreOverride,
    securePlexSessionStoreOverride,
    sharedPreferencesPlexSyncCacheStoreOverride,
    // The audiobook seam's own credential, stored the same encrypted way as
    // the music providers' but entirely separate from them.
    secureAudiobookshelfSessionStoreOverride,
    sharedPreferencesFavoritesStoreOverride,
    remoteFavoritesSyncOverride,
    sharedPreferencesPlaylistStoreOverride,
    remotePlaylistSyncOverride,
    sharedPreferencesPlayHistoryStoreOverride,
    sharedPreferencesAppIconVariantStoreOverride,
    sharedPreferencesThemeModeStoreOverride,
    initialThemeModeProvider.overrideWithValue(storedThemeMode),
    platformLauncherIconServiceOverride,
    platformShareServiceOverride,
    platformAudioOutputDeviceServiceOverride,
    lyricsServiceOverride,
    // Casting is withheld from production builds by the security
    // containment; see [CastContainment].
    containedCastServiceOverride,
  ];
}
