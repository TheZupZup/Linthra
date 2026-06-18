import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/plex_session.dart';
import '../../core/models/subsonic_session.dart';
import '../../core/services/media_artwork_cache.dart';
import '../../core/services/media_artwork_prewarm_service.dart';
import '../../core/sources/plex/plex_artwork.dart';
import '../../core/sources/subsonic/subsonic_artwork.dart';
import '../settings/plex/plex_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import 'player_providers.dart';

/// The pixel size Linthra requests Subsonic and Plex cover art at for the
/// **media session** (lock screen / Android Auto now-playing card). Small enough
/// to download quickly and let the platform decode it without jank or OOM, but
/// crisp on those surfaces. The in-app full-size render (PR #170) is unaffected.
const int kMediaSessionArtworkSize = 512;

/// Resolves a credential-free media-session cover [reference] into an
/// authenticated, ready-to-fetch cover URL for whichever provider owns its
/// scheme, weaving the live session's credential in on demand. Returns `null`
/// for a reference no signed-in provider owns — signed out, or an already
/// platform-loadable Jellyfin/local cover the cache never sees — and the caller
/// then shows no media-session artwork.
///
/// Each provider's resolver owns one reference scheme and returns `null` for the
/// rest, so they chain safely: a `subsonic-cover:` goes to Subsonic, a
/// `plex-thumb:` to Plex. Mirrors `main.dart`'s in-app
/// `installArtworkReferenceResolver`, but asks *each* provider for a media-
/// session-sized cover ([kMediaSessionArtworkSize]) — small and fast to decode
/// on the lock screen / Android Auto card — so Subsonic (`getCoverArt?size=…`)
/// and Plex (a photo-transcode cover) feed the shared artwork cache the same
/// modest-size image rather than a full-resolution one. The credential is woven
/// in here and used once by the cache to fetch; it is never persisted (the
/// catalog stores only the credential-free reference) or logged.
Uri? resolveMediaSessionArtworkUrl(
  Uri reference, {
  SubsonicSession? subsonic,
  PlexSession? plex,
}) {
  if (subsonic != null) {
    final Uri? resolved = SubsonicArtwork.resolve(
      reference,
      subsonic,
      size: kMediaSessionArtworkSize,
    );
    if (resolved != null) return resolved;
  }
  if (plex != null) {
    final Uri? resolved = PlexArtwork.resolve(
      reference,
      plex,
      size: kMediaSessionArtworkSize,
    );
    if (resolved != null) return resolved;
  }
  return null;
}

/// The privacy-safe media-session artwork cache for Subsonic/Navidrome and Plex.
///
/// The platform media session loads `MediaItem.artUri` itself, somewhere Linthra
/// can't add the credential, so a credentialed cover URL (Subsonic's salt+token
/// `getCoverArt`, or Plex's `X-Plex-Token` cover-art URL) must never go there.
/// The cache instead fetches the cover itself (weaving the live session's
/// credential in on demand via [resolveMediaSessionArtworkUrl], used once and
/// never stored or logged), writes the bytes to a private file keyed by a hash
/// of the credential-free reference (`subsonic-cover:` / `plex-thumb:`), and
/// exposes it as a safe local `content://`. Jellyfin (token-free http) and local
/// (`file:`) covers are already platform-loadable and never reach this cache.
/// Reads the sessions live, so sign-in/out is picked up; signed out, or on any
/// fetch failure, it yields no artwork and playback is unaffected.
final mediaArtworkCacheProvider = Provider<MediaArtworkCache>((ref) {
  final cache = MediaArtworkCache(
    resolveUrl: (Uri reference) => resolveMediaSessionArtworkUrl(
      reference,
      subsonic: ref.read(subsonicSettingsControllerProvider.notifier).session,
      plex: ref.read(plexSettingsControllerProvider.notifier).session,
    ),
  );
  ref.onDispose(cache.dispose);
  return cache;
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
