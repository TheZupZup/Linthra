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
/// UI shows its placeholder) rather than loading a stale cover.
abstract final class PlexArtwork {
  /// Resolves a credential-free cover [reference] into a loadable,
  /// authenticated cover-art URL for [session], or `null` when [reference]
  /// isn't a Plex cover reference (so a Jellyfin http URL, a local `file:`
  /// cover, or a `subsonic-cover:` reference passes straight through the
  /// resolver untouched). The token is woven in here, on demand, and never
  /// persisted — the stored reference stays credential-free.
  ///
  /// This never throws — it returns `null` for anything it can't mint a sound
  /// URL from, so the caller's placeholder is the worst case. It runs
  /// synchronously inside widget builds (the `artworkImageProvider` seam), so
  /// a throw would take down the whole frame, not just one cover. Concretely:
  /// a degenerate session (blank address or token) doesn't resolve — a
  /// `plex-thumb:` reference resolves only against a *usable* session; a thumb
  /// path that isn't server-absolute is refused rather than spliced into the
  /// base URL's authority (it could silently point at the wrong host); and a
  /// path the URL parser rejects degrades to the placeholder too.
  static Uri? resolve(Uri reference, PlexSession session) {
    final String? thumbPath = PlexTrackMapper.thumbPath(reference);
    if (thumbPath == null) return null;
    if (session.baseUrl.isEmpty || session.token.isEmpty) return null;
    if (!thumbPath.startsWith('/')) return null;
    try {
      return PlexEndpoints.coverArt(
        session.baseUrl,
        thumbPath: thumbPath,
        token: session.token,
      );
    } on FormatException {
      return null;
    }
  }
}
