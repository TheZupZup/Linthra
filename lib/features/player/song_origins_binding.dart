import '../../core/services/song_origins.dart';
import '../../core/sources/music_provider.dart';
import '../../core/sources/plex/plex_track_mapper.dart';
import '../../core/sources/subsonic/subsonic_account_fingerprint.dart';
import '../../core/sources/subsonic/subsonic_track_mapper.dart';
import '../../data/repositories/playback_session_store_provider.dart';
import '../../data/repositories/song_origins_provider.dart';
import '../settings/plex/plex_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';

/// Production binding for [songOriginsProvider] (#795): Subsonic and Plex
/// references are bound to the account or server signed in, read live from
/// the same sessions the saved play queue keys on (#767). A change of either
/// is announced so whatever resolves stored references re-resolves. Applied
/// in `main`; tests keep the data-layer default (nothing bound).
final songOriginsOverride = songOriginsProvider.overrideWith((ref) {
  final SessionSongOrigins origins = SessionSongOrigins(
    signedIn: (String scheme) =>
        remoteSongOwnerSignedIn(ref, MusicProviders.forTrackUri(scheme)),
    legacyStore: ref.read(songOriginLegacyStoreProvider),
    restoreFailed: (String scheme) => switch (scheme) {
      SubsonicTrackMapper.uriScheme =>
        ref.read(subsonicSettingsControllerProvider.notifier).restoreFailed,
      PlexTrackMapper.uriScheme =>
        ref.read(plexSettingsControllerProvider.notifier).restoreFailed,
      _ => false,
    },
  );
  ref.listen<String?>(
    subsonicMusicSourceProvider.select((source) =>
        source == null ? null : subsonicAccountFingerprint(source.session)),
    (_, __) => origins.changed(),
  );
  ref.listen<String?>(
    plexMusicSourceProvider
        .select((source) => source?.session.machineIdentifier),
    (_, __) => origins.changed(),
  );
  ref.onDispose(origins.close);
  return origins;
});
