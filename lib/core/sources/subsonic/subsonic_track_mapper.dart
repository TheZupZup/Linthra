import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import 'subsonic_api.dart';
import 'subsonic_artwork.dart';

/// Converts Subsonic wire items into Linthra's source-agnostic domain models.
///
/// Kept separate from both the HTTP client (which only parses JSON) and the
/// source (which only orchestrates), so the field-by-field mapping is pure and
/// unit-testable.
///
/// Two deliberate choices:
///  - A track's [Track.uri] is the opaque `subsonic:<id>`, NOT a streaming URL.
///    The real stream/download URLs carry the salt+token, so building them
///    lazily in `SubsonicMusicSource` keeps the credential out of the persisted
///    catalog.
///  - [Track.artworkUri] is a credential-free `subsonic-cover:<coverArtId>`
///    reference, never a ready-to-load URL. Subsonic cover art (`getCoverArt`)
///    requires the auth query, so a loadable URL would embed the credential —
///    and `artworkUri` is persisted in the catalog. The credential is woven in
///    on demand at render time instead (see [SubsonicArtwork]).
///
/// [Track.albumId] is namespaced the same way as [Track.uri] (`subsonic:` +
/// the song's `albumId`), so it can never collide with another provider's
/// album id in `library_grouping.dart` and lets a collaboration track still
/// group under its real album. [Track.albumArtistName] is deliberately left
/// `null`: the classic (non-ID3) Subsonic response this mapper reads has no
/// per-song album-artist field distinct from the song's own `artist`, and
/// guessing one (e.g. reusing `artist`) would be no more reliable than the
/// pre-existing name-only fallback — the [Track.albumId] tier already covers
/// the servers that expose it.
abstract final class SubsonicTrackMapper {
  /// Prefix marking a [Track.uri] as a Subsonic item rather than a file path or
  /// a Jellyfin item.
  static const String uriScheme = 'subsonic:';

  static Track toTrack(SubsonicSongDto song) {
    return Track(
      id: song.id,
      title: song.title,
      uri: '$uriScheme${song.id}',
      artistName: song.artist,
      albumName: song.album,
      albumId: _albumIdReference(song.albumId),
      duration: _durationFromSeconds(song.durationSeconds),
      trackNumber: song.track,
      serverAddedAt: song.dateCreated,
      artworkUri: _artworkReference(song.coverArt),
    );
  }

  static Album toAlbum(SubsonicAlbumDto album) {
    return Album(
      id: album.id,
      title: album.name,
      artistName: album.artist,
      year: album.year,
      trackCount: album.songCount,
      artworkUri: _artworkReference(album.coverArt),
    );
  }

  static Artist toArtist(SubsonicArtistDto artist) {
    return Artist(
      id: artist.id,
      name: artist.name,
      albumCount: artist.albumCount,
      artworkUri: _artworkReference(artist.coverArt),
    );
  }

  /// A persistable `subsonic:<albumId>` album-id reference, or `null` when
  /// [albumId] is absent or blank. Mirrors [Track.uri]'s namespacing so this
  /// can never collide with another provider's album id in
  /// `library_grouping.dart`.
  static String? _albumIdReference(String? albumId) {
    final String? id = _nonBlank(albumId);
    return id == null ? null : '$uriScheme$id';
  }

  /// [value] trimmed, or `null` when it is `null` or blank.
  static String? _nonBlank(String? value) {
    final String? trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// A credential-free [SubsonicArtwork.reference] for a non-empty [coverArtId],
  /// or `null` when the server reported none — so a track/album/artist without
  /// cover art keeps a null `artworkUri` and the UI shows its placeholder.
  static Uri? _artworkReference(String? coverArtId) {
    if (coverArtId == null || coverArtId.isEmpty) return null;
    return SubsonicArtwork.reference(coverArtId);
  }

  /// Subsonic reports a song's duration in whole seconds; absent or zero maps to
  /// [Duration.zero].
  static Duration _durationFromSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return Duration.zero;
    return Duration(seconds: seconds);
  }
}
