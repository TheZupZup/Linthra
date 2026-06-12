import '../../models/plex_session.dart';
import 'plex_endpoints.dart';
import 'plex_track_mapper.dart';

/// Render-time resolution of a credential-free `plex-thumb:` cover reference
/// into an authenticated Plex cover-art URL.
///
/// Why a reference instead of a ready-to-load URL: Plex cover art requires the
/// `X-Plex-Token` as a query param on *every* request (the image layer can't
/// set headers), so a loadable cover URL would embed the credential — and
/// `Track.artworkUri` is persisted in the offline catalog. To keep the same
/// "the credential never reaches the catalog" invariant the stream URLs
/// follow, `PlexTrackMapper` stores only an opaque `plex-thumb:<thumbPath>`
/// reference (no token, no server URL), and [resolve] weaves the live
/// session's token in on demand at render time — exactly how
/// `SubsonicArtwork.resolve` mints `getCoverArt` URLs.
///
/// The reference is provider-scoped, not server-scoped: there is a single
/// signed-in Plex session at a time, so resolution reads whichever session is
/// current. A reference left over after sign-out simply fails to resolve (the
/// UI shows its placeholder) rather than loading a stale cover. Until the Plex
/// connection UI ships, no session can exist, so every `plex-thumb:` reference
/// stays unresolved and invisible.
abstract final class PlexArtwork {
  /// Resolves a credential-free cover [reference] into a loadable,
  /// authenticated cover-art URL for [session], or `null` when [reference]
  /// isn't a Plex cover reference (so a Jellyfin http URL, a local `file:`
  /// cover, or a `subsonic-cover:` reference passes straight through the
  /// resolver untouched). The token is woven in here, on demand, and never
  /// persisted — the stored reference stays credential-free.
  static Uri? resolve(Uri reference, PlexSession session) {
    final String? thumbPath = PlexTrackMapper.thumbPath(reference);
    if (thumbPath == null) return null;
    return PlexEndpoints.coverArt(
      session.baseUrl,
      thumbPath: thumbPath,
      token: session.token,
    );
  }
}
