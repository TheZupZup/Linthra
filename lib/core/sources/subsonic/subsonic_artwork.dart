import '../../models/subsonic_session.dart';
import 'subsonic_auth.dart';
import 'subsonic_endpoints.dart';

/// Subsonic/Navidrome cover art as a *credential-free reference* that is safe to
/// persist in the catalog, plus its render-time resolution into an authenticated
/// `getCoverArt` URL.
///
/// Why a reference instead of a ready-to-load URL: Subsonic's `getCoverArt`
/// requires the salt+token auth query on *every* request, so a loadable cover
/// URL would embed the credential — and `Track.artworkUri` is persisted in the
/// offline catalog. To keep the same "the credential never reaches the catalog"
/// invariant the stream/download URLs follow, the mapper stores only an opaque
/// `subsonic-cover:<coverArtId>` reference (no token, no salt, no server URL),
/// and [resolve] weaves the live session's credential in on demand at render
/// time — exactly how `SubsonicMusicSource.resolvePlayableUri` mints audio URLs.
///
/// The reference is provider-scoped, not server-scoped: there is a single
/// signed-in Subsonic session at a time, so resolution reads whichever session
/// is current. A reference left over after sign-out simply fails to resolve
/// (the UI shows its placeholder) rather than loading a stale cover.
abstract final class SubsonicArtwork {
  /// Scheme marking a [Uri] as a credential-free Subsonic cover reference. A
  /// dedicated scheme (not `subsonic:`, which marks a track URI) keeps it
  /// unambiguous for both the artwork resolver and any diagnostics.
  static const String referenceScheme = 'subsonic-cover';

  /// A persistable, credential-free reference to the server cover art
  /// [coverArtId] (e.g. `subsonic-cover:al-123`). The id rides as a single path
  /// segment so it round-trips exactly through [coverArtId] and through the
  /// catalog's `Uri.toString()` / `Uri.parse` — even for the rare id that needs
  /// percent-encoding (real Subsonic ids are alphanumeric + hyphen).
  static Uri reference(String coverArtId) =>
      Uri(scheme: referenceScheme, pathSegments: <String>[coverArtId]);

  /// The cover-art id behind a [reference], or `null` when [uri] isn't a
  /// Subsonic cover reference (so a Jellyfin http URL or a local `file:` cover
  /// passes straight through the resolver untouched).
  static String? coverArtId(Uri uri) {
    if (!uri.isScheme(referenceScheme)) return null;
    if (uri.pathSegments.isEmpty) return null;
    final String id = uri.pathSegments.first;
    return id.isEmpty ? null : id;
  }

  /// Resolves a credential-free cover [reference] into a loadable, authenticated
  /// `getCoverArt` URL for [session], or `null` when [reference] isn't a
  /// Subsonic cover reference. The salt+token are woven in here, on demand, and
  /// never persisted — the stored reference stays credential-free.
  static Uri? resolve(Uri reference, SubsonicSession session) {
    final String? id = coverArtId(reference);
    if (id == null) return null;
    return SubsonicEndpoints.coverArt(
      session.baseUrl,
      username: session.username,
      credentials:
          SubsonicCredentials(salt: session.salt, token: session.token),
      coverArtId: id,
    );
  }
}
