import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import '../../core/platform/host_platform.dart';
import '../../core/repositories/playback_session_store.dart';
import '../../core/repositories/remote_catalog_owner_store.dart';
import '../../core/services/playback_session_persistence.dart';
import '../../core/sources/jellyfin/jellyfin_account_fingerprint.dart';
import '../../core/sources/music_provider.dart';
import '../../core/sources/subsonic/subsonic_account_fingerprint.dart';
import '../../features/player/player_providers.dart';
import '../../features/settings/jellyfin/jellyfin_settings_controller.dart';
import '../../features/settings/plex/plex_settings_controller.dart';
import '../../features/settings/subsonic/subsonic_settings_controller.dart';
import 'host_platform_provider.dart';
import 'in_memory_playback_session_store.dart';
import 'remote_catalog_owner_store_provider.dart';
import 'shared_preferences_playback_session_store.dart';

/// Durable store of the crash-safe playback session. Defaults to in-memory so
/// tests and non-Linux hosts need no plugins; Linux production overrides it
/// with the `shared_preferences` binding below.
final playbackSessionStoreProvider = Provider<PlaybackSessionStore>((ref) {
  return InMemoryPlaybackSessionStore();
});

/// Production binding: persist the playback session via `shared_preferences`
/// so an unexpected restart can restore the logical queue. Applied in `main`
/// on Linux only; other platforms keep the in-memory default (no restore).
final sharedPreferencesPlaybackSessionStoreOverride =
    playbackSessionStoreProvider.overrideWithValue(
  const SharedPreferencesPlaybackSessionStore(),
);

/// Crash-safe playback session persistence + restore.
///
/// Constructed only on Linux: it listens to the local engine's state stream,
/// writes logical sessions, and restores them paused on startup. Returns
/// `null` on other platforms so Android behaviour is unchanged. Side-effect
/// only; `main` instantiates it once and awaits
/// [PlaybackSessionPersistence.restore].
final playbackSessionPersistenceProvider =
    Provider<PlaybackSessionPersistence?>((ref) {
  if (ref.watch(hostPlatformProvider) != HostPlatform.linux) {
    return null;
  }

  final RemoteCatalogOwnerStore catalogOwners =
      ref.read(remoteCatalogOwnerStoreProvider);
  final PlaybackSessionPersistence service = PlaybackSessionPersistence(
    store: ref.watch(playbackSessionStoreProvider),
    controller: ref.read(localPlaybackControllerProvider),
    playbackStates: ref.read(localPlaybackControllerProvider).stateStream,
    remoteAccountOf: (MusicProvider provider) =>
        remoteSongOwnerSignedIn(ref, provider),
    queueOwnerOf: (MusicProvider provider) async {
      // Plex's library goes whenever its server does, and the queue's Plex
      // songs with it, so the ones queued are the connected server's.
      if (identical(provider, MusicProviders.plex)) {
        return remoteSongOwnerSignedIn(ref, provider);
      }
      // The queue follows the library (#767): its songs are the account's
      // whose library this is. That is the signed-in account once it has
      // taken the library over, and still the last one after it signed out.
      return await catalogOwners.read(provider.sourceId) ??
          remoteSongOwnerSignedIn(ref, provider);
    },
  );
  ref.onDisposeAsync(service.dispose);
  return service;
});

/// Who [provider]'s songs would play for now, as the same non-secret keys the
/// sync stores and smart pre-cache use, or null while it is signed out. Also
/// what a stored reference to one of its songs records (`SongOrigins`, #795).
String? remoteSongOwnerSignedIn(Ref ref, MusicProvider provider) {
  if (identical(provider, MusicProviders.jellyfin)) {
    final source = ref.read(jellyfinMusicSourceProvider);
    return source == null ? null : jellyfinAccountFingerprint(source.session);
  }
  if (identical(provider, MusicProviders.subsonic)) {
    final source = ref.read(subsonicMusicSourceProvider);
    return source == null ? null : subsonicAccountFingerprint(source.session);
  }
  if (identical(provider, MusicProviders.plex)) {
    // Every profile on one server shares its ratingKeys, so the server is
    // what the songs belong to.
    return ref.read(plexMusicSourceProvider)?.session.machineIdentifier;
  }
  return null;
}
