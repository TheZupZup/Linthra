/// Wire models for the Jellyfin REST API.
///
/// These mirror the JSON shapes the server returns and live behind
/// [JellyfinClient]; nothing outside the Jellyfin source should touch them.
/// Mapping them to Linthra's [Track]/[Album]/[Artist] is the
/// `JellyfinTrackMapper`'s job, keeping HTTP parsing and domain mapping
/// separate.
library;

/// Which kind of music item to list. Maps to a Jellyfin item type / endpoint
/// inside the client, so the source can ask for "tracks" without knowing the
/// query string.
enum JellyfinItemKind { audio, album, artist }

/// Public server info from `GET /System/Info/Public` — enough to confirm the
/// address is a Jellyfin server and to show the user which one they reached.
class JellyfinServerInfo {
  const JellyfinServerInfo({
    required this.serverName,
    required this.version,
    this.id,
  });

  final String serverName;
  final String version;
  final String? id;

  /// Parses the response, or returns `null` when the body lacks the fields a
  /// real Jellyfin server always sends (so the client can report "not a
  /// Jellyfin server" instead of surfacing a half-empty object).
  static JellyfinServerInfo? fromJson(Map<String, dynamic> json) {
    final String? name = json['ServerName'] as String?;
    final String? version = json['Version'] as String?;
    if (name == null || version == null) return null;
    return JellyfinServerInfo(
      serverName: name,
      version: version,
      id: json['Id'] as String?,
    );
  }
}

/// Result of `POST /Users/AuthenticateByName`.
///
/// Carries the secret [accessToken]; [toString] redacts it so the result can't
/// leak the token through logs.
class JellyfinAuthResult {
  const JellyfinAuthResult({
    required this.accessToken,
    required this.userId,
    this.userName,
    this.serverId,
  });

  final String accessToken;
  final String userId;
  final String? userName;
  final String? serverId;

  /// Parses the auth response, or returns `null` if the token/user are absent
  /// (an unexpected body) so the client can fail clearly.
  static JellyfinAuthResult? fromJson(Map<String, dynamic> json) {
    final String? token = json['AccessToken'] as String?;
    final Object? user = json['User'];
    final String? userId =
        user is Map<String, dynamic> ? user['Id'] as String? : null;
    if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
      return null;
    }
    return JellyfinAuthResult(
      accessToken: token,
      userId: userId,
      userName: user is Map<String, dynamic> ? user['Name'] as String? : null,
      serverId: json['ServerId'] as String?,
    );
  }

  @override
  String toString() => 'JellyfinAuthResult(userId: $userId, '
      'userName: $userName, serverId: $serverId, accessToken: <redacted>)';
}

/// A single library item (track, album, or artist) from `/Items` or `/Artists`.
///
/// Only the fields Linthra maps today are kept; the rest of the (large)
/// Jellyfin item payload is ignored.
class JellyfinItemDto {
  const JellyfinItemDto({
    required this.id,
    required this.name,
    this.album,
    this.albumId,
    this.albumArtist,
    this.artists = const <String>[],
    this.runTimeTicks,
    this.indexNumber,
    this.productionYear,
    this.childCount,
    this.hasPrimaryImage = false,
  });

  final String id;
  final String name;
  final String? album;
  final String? albumId;
  final String? albumArtist;
  final List<String> artists;

  /// Duration in Jellyfin "ticks" (100-nanosecond units), when present.
  final int? runTimeTicks;
  final int? indexNumber;
  final int? productionYear;
  final int? childCount;

  /// Whether the server has primary cover art for this item, so the mapper only
  /// builds an artwork URL when there's actually an image to fetch.
  final bool hasPrimaryImage;

  /// Parses one item, or returns `null` when it lacks an id/name (skipped by
  /// the caller) so a single malformed entry can't break a whole listing.
  static JellyfinItemDto? fromJson(Map<String, dynamic> json) {
    final String? id = json['Id'] as String?;
    final String? name = json['Name'] as String?;
    if (id == null || id.isEmpty || name == null) return null;

    final Object? rawArtists = json['Artists'];
    final List<String> artists = rawArtists is List
        ? <String>[
            for (final Object? a in rawArtists)
              if (a is String && a.isNotEmpty) a,
          ]
        : const <String>[];

    final Object? imageTags = json['ImageTags'];
    final bool hasPrimary = imageTags is Map && imageTags['Primary'] != null;

    return JellyfinItemDto(
      id: id,
      name: name,
      album: json['Album'] as String?,
      albumId: json['AlbumId'] as String?,
      albumArtist: json['AlbumArtist'] as String?,
      artists: artists,
      runTimeTicks: (json['RunTimeTicks'] as num?)?.toInt(),
      indexNumber: (json['IndexNumber'] as num?)?.toInt(),
      productionYear: (json['ProductionYear'] as num?)?.toInt(),
      childCount: (json['ChildCount'] as num?)?.toInt(),
      hasPrimaryImage: hasPrimary,
    );
  }
}
