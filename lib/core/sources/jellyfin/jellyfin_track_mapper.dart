import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import 'jellyfin_api.dart';
import 'jellyfin_endpoints.dart';

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
///
/// [Track.albumId] is namespaced the same way as [Track.uri] (`jellyfin:` +
/// the server's `AlbumId`), so it can never collide with another provider's
/// album id in `library_grouping.dart`. [Track.albumArtistName] is Jellyfin's
/// own `AlbumArtist`, passed through as-is — both let a collaboration track
/// (whose per-track [Track.artistName] differs from the rest of the album's)
/// still group under the one album it belongs to.
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
      albumId: _albumIdReference(item.albumId),
      albumArtistName: item.albumArtist,
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

  /// A persistable `jellyfin:<albumId>` album-id reference, or `null` when
  /// [albumId] is absent or blank ([JellyfinItemDto.albumId] is already
  /// blank-filtered by `_coerceString`, but this guard is cheap insurance
  /// against a future DTO change). Mirrors [Track.uri]'s namespacing so this
  /// can never collide with another provider's album id in
  /// `library_grouping.dart`.
  static String? _albumIdReference(String? albumId) {
    if (albumId == null || albumId.isEmpty) return null;
    return '$uriScheme$albumId';
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
    return JellyfinEndpoints.primaryImage(
      baseUrl,
      itemId: item.id,
      tag: item.primaryImageTag,
    );
  }
}
