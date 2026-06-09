import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/subsonic_session.dart';
import '../../core/services/media_artwork_cache.dart';
import '../../core/services/media_artwork_prewarm_service.dart';
import '../../core/sources/subsonic/subsonic_artwork.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import 'player_providers.dart';

/// The pixel size Linthra requests Subsonic cover art at for the **media
/// session** (lock screen / Android Auto now-playing card). Small enough to
/// download quickly and let the platform decode it without jank or OOM, but
/// crisp on those surfaces. The in-app full-size render (PR #170) is unaffected.
const int kMediaSessionArtworkSize = 512;

/// The privacy-safe media-session artwork cache for Subsonic/Navidrome.
///
/// The platform media session loads `MediaItem.artUri` itself, somewhere Linthra
/// can't add the salt+token, so the credentialed `getCoverArt` URL must never go
/// there. The cache instead fetches a **server-downscaled** cover itself
/// (weaving the live session's salt+token in on demand, used once and never
/// stored or logged), writes the bytes to a private file keyed by a hash of the
/// credential-free `subsonic-cover:` reference, and exposes it as a safe local
/// `file:`. Jellyfin (token-free http) and local (`file:`) covers are already
/// platform-loadable and never reach this cache. Reads the session live, so
/// sign-in/out is picked up; signed out, or on any fetch failure, it yields no
/// artwork and playback is unaffected.
final mediaArtworkCacheProvider = Provider<MediaArtworkCache>((ref) {
  return MediaArtworkCache(
    resolveUrl: (Uri reference) {
      final SubsonicSession? session =
          ref.read(subsonicSettingsControllerProvider.notifier).session;
      if (session == null) return null;
      return SubsonicArtwork.resolve(
        reference,
        session,
        size: kMediaSessionArtworkSize,
      );
    },
  );
});

/// Warms the now-playing + look-ahead covers into [mediaArtworkCacheProvider]
/// off the playback path, so a cover is cached before its track reaches the
/// now-playing card (beating the head unit's metadata snapshot). Side-effect
/// only — like the stream preloader, instantiating it wires the listener; the
/// UI reads no value from it.
final mediaArtworkPrewarmServiceProvider =
    Provider<MediaArtworkPrewarmService>((ref) {
  final service = MediaArtworkPrewarmService(
    playbackStates: ref.read(playbackControllerProvider).stateStream,
    warm: ref.read(mediaArtworkCacheProvider).resolve,
  );
  ref.onDispose(service.dispose);
  return service;
});
