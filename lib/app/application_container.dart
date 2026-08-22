import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/theme_mode_preference.dart';
import '../core/platform/host_platform.dart';
import '../data/repositories/app_icon_variant_store_provider.dart';
import '../data/repositories/default_provider_store_provider.dart';
import '../data/repositories/download_repository_provider.dart';
import '../data/repositories/favorites_repository_provider.dart';
import '../data/repositories/jellyfin_auto_sync_store_provider.dart';
import '../data/repositories/jellyfin_session_store_provider.dart';
import '../data/repositories/launcher_icon_service_provider.dart';
import '../data/repositories/library_added_store_provider.dart';
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
    sharedPreferencesSelectedMusicFolderRepositoryOverride,
    sharedPreferencesPreferredSourceStoreOverride,
    sharedPreferencesDefaultProviderStoreOverride,
    sharedPreferencesPlaybackSourceStrategyStoreOverride,
    offlineAvailableTrackKeysOverride,
    sharedPreferencesDownloadStoreOverride,
    sharedPreferencesDownloadPreferencesOverride,
    sharedPreferencesPlaybackPreferencesOverride,
    if (resolvedHost == HostPlatform.linux)
      sharedPreferencesPlaybackSessionStoreOverride,
    fileSystemOfflineFileStoreOverride,
    remoteTrackDownloaderOverride,
    playbackCandidateSourceOverride,
    currentlyPlayingTrackOverride,
    nowPlayingOverride,
    secureJellyfinSessionStoreOverride,
    sharedPreferencesJellyfinAutoSyncStoreOverride,
    secureSubsonicSessionStoreOverride,
    sharedPreferencesSubsonicAutoSyncStoreOverride,
    securePlexSessionStoreOverride,
    sharedPreferencesPlexSyncCacheStoreOverride,
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
    lyricsServiceOverride,
    chromecastCastServiceOverride,
  ];
}
