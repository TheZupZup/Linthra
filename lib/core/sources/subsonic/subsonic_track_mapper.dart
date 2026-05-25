import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import 'subsonic_api.dart';

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
///  - [Track.artworkUri] is intentionally left null. Subsonic cover art
///    (`getCoverArt`) requires the auth query, so a cover URL would embed the
///    credential — and `artworkUri` is persisted in the catalog. Token-free
///    cover-art resolution is a documented follow-up (see docs/providers.md).
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
      duration: _durationFromSeconds(song.durationSeconds),
      trackNumber: song.track,
    );
  }

  static Album toAlbum(SubsonicAlbumDto album) {
    return Album(
      id: album.id,
      title: album.name,
      artistName: album.artist,
      year: album.year,
      trackCount: album.songCount,
    );
  }

  static Artist toArtist(SubsonicArtistDto artist) {
    return Artist(
      id: artist.id,
      name: artist.name,
      albumCount: artist.albumCount,
    );
  }

  /// Subsonic reports a song's duration in whole seconds; absent or zero maps to
  /// [Duration.zero].
  static Duration _durationFromSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return Duration.zero;
    return Duration(seconds: seconds);
  }
}
