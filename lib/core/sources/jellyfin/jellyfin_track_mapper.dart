import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import 'jellyfin_api.dart';

/// Converts Jellyfin wire items into Linthra's source-agnostic domain models.
///
/// Kept separate from both the HTTP client (which only parses JSON) and the
/// source (which only orchestrates), so the field-by-field mapping is pure and
/// unit-testable.
///
/// Two deliberate choices:
///  - A track's [Track.uri] is the opaque `jellyfin:<itemId>`, NOT a streaming
///    URL. The real stream URL carries the access token, so building it lazily
///    in `JellyfinMusicSource.resolvePlayableUri` keeps the token out of the
///    persisted catalog.
///  - Artwork is a plain URL to the item's primary image; it needs no token, so
///    it's safe to cache.
abstract final class JellyfinTrackMapper {
  /// Prefix marking a [Track.uri] as a Jellyfin item rather than a file path.
  static const String uriScheme = 'jellyfin:';

  static Track toTrack(JellyfinItemDto item, {required String baseUrl}) {
    return Track(
      id: item.id,
      title: item.name,
      uri: '$uriScheme${item.id}',
      artistName: _primaryArtist(item),
      albumName: item.album,
      duration: _durationFromTicks(item.runTimeTicks),
      trackNumber: item.indexNumber,
      artworkUri: _artworkUri(baseUrl, item),
    );
  }

  static Album toAlbum(JellyfinItemDto item, {required String baseUrl}) {
    return Album(
      id: item.id,
      title: item.name,
      artistName: item.albumArtist ?? _primaryArtist(item),
      year: item.productionYear,
      artworkUri: _artworkUri(baseUrl, item),
      trackCount: item.childCount ?? 0,
    );
  }

  static Artist toArtist(JellyfinItemDto item, {required String baseUrl}) {
    return Artist(
      id: item.id,
      name: item.name,
      artworkUri: _artworkUri(baseUrl, item),
    );
  }

  /// Jellyfin durations are in "ticks" (100-nanosecond units); 10 ticks make a
  /// microsecond. Absent or zero ticks map to [Duration.zero].
  static Duration _durationFromTicks(int? ticks) {
    if (ticks == null || ticks <= 0) {
      return Duration.zero;
    }
    return Duration(microseconds: ticks ~/ 10);
  }

  static String? _primaryArtist(JellyfinItemDto item) {
    if (item.albumArtist != null && item.albumArtist!.isNotEmpty) {
      return item.albumArtist;
    }
    return item.artists.isNotEmpty ? item.artists.first : null;
  }

  static Uri? _artworkUri(String baseUrl, JellyfinItemDto item) {
    if (!item.hasPrimaryImage) {
      return null;
    }
    return Uri.parse('$baseUrl/Items/${item.id}/Images/Primary');
  }
}
