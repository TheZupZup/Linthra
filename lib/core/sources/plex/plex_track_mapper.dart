import '../../catalog/library_grouping.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import 'plex_api.dart';

/// Converts Plex wire items into Linthra's source-agnostic domain models.
///
/// Kept separate from both the HTTP client (which only parses JSON) and the
/// source (which only orchestrates), so the field-by-field mapping is pure and
/// unit-testable — exactly like `JellyfinTrackMapper` / `SubsonicTrackMapper`.
/// One [PlexMetadata] DTO covers all three music kinds; which method applies
/// follows Plex's numeric metadata types ([PlexMetadataType]): **8 →
/// [toArtist], 9 → [toAlbum], 10 → [toTrack]**, matching the `type=` filter
/// the source lists each kind with.
///
/// Two deliberate choices (see docs/plex.md → Token safety rules):
///  - A track's [Track.uri] is the opaque `plex:<ratingKey>`, NOT a playable
///    URL. The playable URL needs the `Part` path *and* carries the
///    `X-Plex-Token` in its query, so `PlexMusicSource.resolvePlayableUri`
///    mints it lazily at play time; the persisted catalog never sees a Part
///    path or the token.
///  - [Track.artworkUri] is a credential-free `plex-thumb:<thumbPath>`
///    reference (mirroring Subsonic's `subsonic-cover:`), never a ready-to-load
///    URL. Plex cover art requires the token as a query param, so a loadable
///    URL would embed the credential — and `artworkUri` is persisted in the
///    catalog. The token (and server address) are woven in only at render time
///    by the artwork resolver (a later PR).
///
/// Relationships: the domain models reference artists/albums by *name* — there
/// is no album/artist id slot on [Track]/[Album] today (grouping is name-based,
/// see `library_grouping.dart`) — so the parent/grandparent links Plex reports
/// are carried via their titles: a track's `grandparentTitle` →
/// [Track.artistName] and `parentTitle` → [Track.albumName]; an album's
/// `parentTitle` → [Album.artistName]. When PMS omits them they stay `null`
/// and the grouping layer folds the item into its Unknown Album/Artist buckets.
abstract final class PlexTrackMapper {
  /// Prefix marking a [Track.uri] as a Plex item (`plex:<ratingKey>`) rather
  /// than a file path or another provider's item.
  static const String uriScheme = 'plex:';

  /// Scheme marking a [Uri] as a credential-free Plex cover-art reference
  /// (`plex-thumb:<thumbPath>`). A dedicated scheme (not `plex:`, which marks
  /// a track URI) keeps it unambiguous for the render-time resolver and any
  /// diagnostics.
  static const String artworkScheme = 'plex-thumb';

  /// Display fallback for the rare track whose Plex `title` is missing/blank.
  static const String _untitledTrack = 'Untitled';

  /// Maps a **track** (Plex type 10) listing/metadata item.
  ///
  /// `PlexMetadata` doesn't parse a track index yet, so [Track.trackNumber]
  /// stays `null` (a follow-up, like year/track-count on albums).
  static Track toTrack(PlexMetadata item) {
    return Track(
      id: item.ratingKey,
      title: _nonBlank(item.title) ?? _untitledTrack,
      uri: '$uriScheme${item.ratingKey}',
      artistName: _nonBlank(item.grandparentTitle),
      albumName: _nonBlank(item.parentTitle),
      duration: _durationFromMillis(item.duration),
      artworkUri: _artworkReference(item.thumb),
    );
  }

  /// Maps an **album** (Plex type 9) listing item. Year and track count aren't
  /// parsed from Plex yet, so they keep their defaults.
  static Album toAlbum(PlexMetadata item) {
    return Album(
      id: item.ratingKey,
      title: _nonBlank(item.title) ?? kUnknownAlbum,
      artistName: _nonBlank(item.parentTitle),
      artworkUri: _artworkReference(item.thumb),
    );
  }

  /// Maps an **artist** (Plex type 8) listing item.
  static Artist toArtist(PlexMetadata item) {
    return Artist(
      id: item.ratingKey,
      name: _nonBlank(item.title) ?? kUnknownArtist,
      artworkUri: _artworkReference(item.thumb),
    );
  }

  /// The decoded thumb path behind a `plex-thumb:` [reference], or `null` when
  /// it isn't one — so other artwork (a Jellyfin http URL, a local `file:`
  /// cover, a `subsonic-cover:` reference) passes through the render-time
  /// resolver untouched.
  ///
  /// Decoded, because [_artworkReference] percent-encodes the server-reported
  /// path to ride as a [Uri] path and the raw `Uri.path` getter hands that
  /// encoding back. Returning it undecoded would corrupt any thumb with a
  /// reserved character — most notably a sizing-transcoder thumb
  /// (`/photo/:/transcode?url=…&width=…`), whose `?` would reach the server as
  /// a literal `%3F` path character instead of starting its query. Decoding
  /// restores exactly the string PMS reported, so the render-time resolver
  /// rebuilds the URL the server actually serves. A reference whose path can't
  /// be decoded (only constructible by hand — both the builder and `Uri.parse`
  /// normalize escapes) is `null`, never a throw: artwork resolution runs
  /// inside widget builds.
  static String? thumbPath(Uri reference) {
    if (!reference.isScheme(artworkScheme)) return null;
    final String path = reference.path;
    if (path.isEmpty) return null;
    try {
      return Uri.decodeComponent(path);
    } on FormatException {
      return null;
    }
  }

  /// A persistable, credential-free `plex-thumb:` reference to an item's
  /// server-absolute `thumb` path, or `null` when the item reports none (the
  /// UI then shows its placeholder). The path rides as the [Uri] path so it
  /// round-trips exactly through the catalog's `Uri.toString()` / `Uri.parse`
  /// and back out via [thumbPath]. No token, no server address: both are woven
  /// in only at render time, never persisted.
  ///
  /// Literal `%` is escaped *before* the [Uri] constructor encodes the rest,
  /// because the constructor preserves any valid pre-existing escape triplet:
  /// fed a transcoder thumb whose `url=` value PMS already percent-encoded
  /// (`…?url=http%3A%2F%2F…%26b%3D2&width=…`), it would keep the server's
  /// `%3A`/`%26` as-is while adding its own `%3F` for the `?` — two encoding
  /// levels collapsed into one, which [thumbPath]'s single decode could not
  /// tell apart (it would strip the server's level too, promoting the inner
  /// `&b=2` to a top-level param and corrupting the cover request). With `%`
  /// pre-escaped, exactly one encoding level ever exists, so the single
  /// decode restores the reported string byte-for-byte for every input.
  static Uri? _artworkReference(String? thumb) {
    final String? path = _nonBlank(thumb);
    if (path == null) return null;
    return Uri(scheme: artworkScheme, path: path.replaceAll('%', '%25'));
  }

  /// Plex reports durations in whole **milliseconds** (unlike Subsonic's
  /// seconds or Jellyfin's ticks); absent or zero maps to [Duration.zero].
  static Duration _durationFromMillis(int? millis) {
    if (millis == null || millis <= 0) return Duration.zero;
    return Duration(milliseconds: millis);
  }

  /// Trims [text] and treats blank as absent, so a whitespace-only Plex field
  /// falls back the same way a missing one does.
  static String? _nonBlank(String? text) {
    final String? trimmed = text?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
