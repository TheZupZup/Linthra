import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/plex_session.dart';
import '../core/models/subsonic_session.dart';
import '../core/services/artwork_disk_cache.dart';
import '../core/services/media_session_binding.dart';
import '../core/services/playback_session_persistence.dart';
import '../core/sources/plex/plex_artwork.dart';
import '../core/sources/subsonic/subsonic_artwork.dart';
import '../data/repositories/download_repository_provider.dart';
import '../data/repositories/favorites_repository_provider.dart';
import '../data/repositories/music_library_repository_provider.dart';
import '../data/repositories/playback_session_store_provider.dart';
import '../data/repositories/playlist_repository_provider.dart';
import '../data/repositories/remote_cache_index_provider.dart';
import '../features/player/media_artwork_providers.dart';
import '../features/player/player_providers.dart';
import '../features/settings/jellyfin/jellyfin_settings_controller.dart';
import '../features/settings/playback/normalize_volume_controller.dart';
import '../features/settings/plex/plex_settings_controller.dart';
import '../features/settings/subsonic/subsonic_settings_controller.dart';
import '../shared/widgets/artwork_image.dart';

export 'application_container.dart' show productionApplicationOverrides;

/// Owns the root [ProviderContainer] and every resource `main()` installs
/// outside Riverpod. [shutdown] is idempotent and safe after partial startup.
class ApplicationHandle {
  ApplicationHandle({
    required this.container,
    required this.normalizeVolumeSubscription,
    this.artworkDiskCache,
  });

  final ProviderContainer container;
  final ProviderSubscription<AsyncValue<bool>> normalizeVolumeSubscription;
  final ArtworkDiskCache? artworkDiskCache;

  bool _shutDown = false;

  /// Stops active playback, releases globals installed at bootstrap, and
  /// disposes the root container (which runs every `ref.onDispose` hook).
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;

    if (container.exists(playbackControllerProvider)) {
      try {
        await container.read(playbackControllerProvider).stop();
      } catch (_) {
        // Best-effort: shutdown must never throw.
      }
    }

    if (container.exists(playbackControllerProvider)) {
      try {
        await container.read(playbackControllerProvider).dispose();
      } catch (_) {}
    }
    if (container.exists(localPlaybackControllerProvider)) {
      try {
        await container.read(localPlaybackControllerProvider).dispose();
      } catch (_) {}
    }

    normalizeVolumeSubscription.close();

    artworkDiskCache?.dispose();
    installArtworkDiskCache(null);
    installArtworkReferenceResolver(null);

    container.dispose();
  }
}

/// Wires the same side-effect services and session warm-up `main()` performs
/// between container creation and `runApp`.
Future<ApplicationHandle> bootstrapApplication(
  ProviderContainer container, {
  bool installPersistentArtworkCache = true,
  Directory? artworkCacheDirectory,
}) async {
  await const PlatformMediaSessionBinding().attach(
    container.read(playbackControllerProvider),
    container.read(musicLibraryRepositoryProvider),
    playlists: container.read(playlistRepositoryProvider),
    favorites: container.read(favoritesRepositoryProvider),
    downloads: container.read(downloadRepositoryProvider),
    artwork: container.read(mediaArtworkCacheProvider),
  );

  container.read(mediaArtworkPrewarmServiceProvider);
  container.read(smartPrecacheServiceProvider);
  container.read(remotePrebufferServiceProvider);
  unawaited(container.read(remoteCacheIndexProvider).load());
  container.read(playbackReportingServiceProvider);
  container.read(remoteControlServiceProvider);
  container.read(remoteControlActivatorProvider);

  final ProviderSubscription<AsyncValue<bool>> normalizeVolumeSubscription =
      container.listen<AsyncValue<bool>>(
    normalizeVolumeControllerProvider,
    (_, next) {
      container
          .read(localPlaybackControllerProvider)
          .setVolumeNormalizationEnabled(next.valueOrNull ?? false);
    },
    fireImmediately: true,
  );

  try {
    await container
        .read(jellyfinSettingsControllerProvider.notifier)
        .ensureLoaded();
  } catch (_) {}

  try {
    await container
        .read(subsonicSettingsControllerProvider.notifier)
        .ensureLoaded();
  } catch (_) {}

  try {
    await container
        .read(plexSettingsControllerProvider.notifier)
        .ensureLoaded();
  } catch (_) {}

  Uri? resolveArtworkReference(Uri reference) {
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
  }

  installArtworkReferenceResolver(resolveArtworkReference);

  ArtworkDiskCache? artworkDiskCache;
  if (installPersistentArtworkCache) {
    artworkDiskCache = ArtworkDiskCache(
      directory:
          artworkCacheDirectory ?? await ArtworkDiskCache.defaultDirectory(),
      resolveFetchUrl: (Uri key) => resolveArtworkReference(key) ?? key,
    );
    installArtworkDiskCache(artworkDiskCache);
  }

  unawaited(container.read(favoritesRepositoryProvider).refreshFromRemote());
  unawaited(container.read(playlistRepositoryProvider).refreshFromRemote());

  final PlaybackSessionPersistence? sessionPersistence =
      container.read(playbackSessionPersistenceProvider);
  if (sessionPersistence != null) {
    try {
      await sessionPersistence.restore();
    } catch (_) {}
  }

  return ApplicationHandle(
    container: container,
    normalizeVolumeSubscription: normalizeVolumeSubscription,
    artworkDiskCache: artworkDiskCache,
  );
}
