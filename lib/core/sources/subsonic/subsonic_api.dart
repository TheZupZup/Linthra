/// Wire models for the Subsonic REST API (and OpenSubsonic extensions).
///
/// These mirror the JSON shapes a Subsonic-compatible server (such as
/// Navidrome) returns and live behind [SubsonicClient]; nothing outside the
/// Subsonic source should touch them. Mapping them to Linthra's
/// [Track]/[Album]/[Artist] is the `SubsonicTrackMapper`'s job, keeping HTTP
/// parsing and domain mapping separate.
///
/// Only the fields Linthra maps today are kept; the rest of each (large) item
/// payload is ignored.
library;

/// The `subsonic-response` envelope every Subsonic API call returns.
///
/// A request can fail with a Subsonic error *inside a 200 response* (e.g.
/// `status: "failed"` with `error.code: 40` for bad credentials), so the client
/// must inspect this rather than rely on the HTTP status alone. The [data] map
/// is the envelope itself, from which the typed parsers below pull their fields.
class SubsonicEnvelope {
  const SubsonicEnvelope({
    required this.status,
    required this.data,
    this.errorCode,
    this.errorMessage,
    this.version,
    this.type,
    this.serverVersion,
  });

  /// `"ok"` or `"failed"`.
  final String status;

  /// The full `subsonic-response` object, so a parser can read its data fields.
  final Map<String, dynamic> data;

  /// The Subsonic error code when [status] is `failed` (e.g. 40 = wrong
  /// credentials, 70 = not found), or `null` on success.
  final int? errorCode;

  /// The server's error text. Not shown verbatim to the user (it could change
  /// across servers); the client maps [errorCode] to a friendly message.
  final String? errorMessage;

  /// The Subsonic API version the server speaks (`version`).
  final String? version;

  /// OpenSubsonic server product (`type`, e.g. `navidrome`), when present.
  final String? type;

  /// OpenSubsonic server version (`serverVersion`), when present.
  final String? serverVersion;

  bool get isOk => status == 'ok';

  /// Parses the top-level body, or returns `null` when it isn't a
  /// `subsonic-response` envelope (so the client can report "not a Subsonic
  /// server" rather than surfacing a half-empty object).
  static SubsonicEnvelope? fromJson(Map<String, dynamic> json) {
    final Object? raw = json['subsonic-response'];
    if (raw is! Map<String, dynamic>) return null;
    final Object? status = raw['status'];
    if (status is! String) return null;
    final Object? error = raw['error'];
    return SubsonicEnvelope(
      status: status,
      data: raw,
      errorCode: error is Map<String, dynamic> ? error['code'] as int? : null,
      errorMessage:
          error is Map<String, dynamic> ? error['message'] as String? : null,
      version: raw['version'] as String?,
      type: raw['type'] as String?,
      serverVersion: raw['serverVersion'] as String?,
    );
  }
}

/// Public server identity from a successful `ping`: enough to confirm the
/// address is a Subsonic-compatible server and to record its product/version
/// for display and diagnostics.
class SubsonicServerInfo {
  const SubsonicServerInfo({
    this.apiVersion,
    this.type,
    this.serverVersion,
  });

  /// The Subsonic API version (`version`), e.g. `1.16.1`.
  final String? apiVersion;

  /// OpenSubsonic product (`type`, e.g. `navidrome`), when reported.
  final String? type;

  /// OpenSubsonic server version (`serverVersion`), when reported.
  final String? serverVersion;

  /// A friendly product label for the UI ("Navidrome", "Subsonic", …),
  /// title-casing the reported [type] when one exists.
  String get displayProduct {
    final String? t = type;
    if (t == null || t.isEmpty) return 'Subsonic';
    return t[0].toUpperCase() + t.substring(1);
  }
}

/// What a tiny pre-flight request to a minted stream URL observed.
///
/// The source probes the stream URL before handing it to the audio engine so a
/// reverse-proxy/Cloudflare page or a non-audio response becomes a precise,
/// friendly error instead of an opaque engine failure. Only the (non-secret)
/// HTTP status and content type are carried — never the URL or the token woven
/// into it. Mirrors `JellyfinStreamProbe`.
class SubsonicStreamProbe {
  const SubsonicStreamProbe({required this.statusCode, this.contentType});

  final int statusCode;
  final String? contentType;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// The server answered with an HTML page (a Cloudflare/login/reverse-proxy
  /// page) where audio was expected.
  bool get isHtml {
    final String? type = _mimeType;
    return type != null && type.startsWith('text/html');
  }

  /// The body looks like something the audio engine can open (an `audio/*`
  /// type, the generic binary `application/octet-stream` some servers use, or a
  /// missing content type — lenient, since the engine sniffs the container).
  bool get isAudio {
    final String? type = _mimeType;
    if (type == null) return true;
    return type.startsWith('audio/') ||
        type.startsWith('video/') ||
        type == 'application/octet-stream';
  }

  String? get _mimeType {
    final String? raw = contentType;
    if (raw == null) return null;
    final String type = raw.split(';').first.trim().toLowerCase();
    return type.isEmpty ? null : type;
  }
}

/// An artist from `getArtists` (the ID3 browsing endpoint).
class SubsonicArtistDto {
  const SubsonicArtistDto({
    required this.id,
    required this.name,
    this.albumCount = 0,
    this.coverArt,
  });

  final String id;
  final String name;
  final int albumCount;

  /// The server's cover-art id for this artist, when present. An opaque handle
  /// (e.g. `ar-123`) the `getCoverArt` endpoint resolves to an image — not a
  /// URL and not a credential. Maps to the artist's artwork.
  final String? coverArt;

  static SubsonicArtistDto? fromJson(Map<String, dynamic> json) {
    final String? id = json['id'] as String?;
    final String? name = json['name'] as String?;
    if (id == null || id.isEmpty || name == null) return null;
    return SubsonicArtistDto(
      id: id,
      name: name,
      albumCount: (json['albumCount'] as num?)?.toInt() ?? 0,
      coverArt: json['coverArt'] as String?,
    );
  }
}

/// An album from `getAlbumList2` (the ID3 album list).
class SubsonicAlbumDto {
  const SubsonicAlbumDto({
    required this.id,
    required this.name,
    this.artist,
    this.songCount = 0,
    this.year,
    this.coverArt,
  });

  final String id;
  final String name;
  final String? artist;
  final int songCount;
  final int? year;

  /// The server's cover-art id for this album, when present. An opaque handle
  /// (e.g. `al-123`) the `getCoverArt` endpoint resolves to an image — not a
  /// URL and not a credential. Maps to the album's artwork.
  final String? coverArt;

  static SubsonicAlbumDto? fromJson(Map<String, dynamic> json) {
    final String? id = json['id'] as String?;
    final String? name = json['name'] as String?;
    if (id == null || id.isEmpty || name == null) return null;
    return SubsonicAlbumDto(
      id: id,
      name: name,
      artist: json['artist'] as String?,
      songCount: (json['songCount'] as num?)?.toInt() ?? 0,
      year: (json['year'] as num?)?.toInt(),
      coverArt: json['coverArt'] as String?,
    );
  }
}

/// A song/track from `getAlbum` (an album's child list).
class SubsonicSongDto {
  const SubsonicSongDto({
    required this.id,
    required this.title,
    this.album,
    this.artist,
    this.track,
    this.durationSeconds,
    this.coverArt,
  });

  final String id;
  final String title;
  final String? album;
  final String? artist;

  /// The track number within its album, when present.
  final int? track;

  /// Duration in whole seconds, when present (Subsonic reports `duration` in
  /// seconds, unlike Jellyfin's 100-ns ticks).
  final int? durationSeconds;

  /// The server's cover-art id for this song, when present. An opaque handle
  /// (typically the album's, e.g. `al-123`, or the song's own `mf-123`) the
  /// `getCoverArt` endpoint resolves to an image — not a URL and not a
  /// credential. Maps to the track's artwork.
  final String? coverArt;

  static SubsonicSongDto? fromJson(Map<String, dynamic> json) {
    final String? id = json['id'] as String?;
    final String? title = json['title'] as String?;
    if (id == null || id.isEmpty || title == null) return null;
    return SubsonicSongDto(
      id: id,
      title: title,
      album: json['album'] as String?,
      artist: json['artist'] as String?,
      track: (json['track'] as num?)?.toInt(),
      durationSeconds: (json['duration'] as num?)?.toInt(),
      coverArt: json['coverArt'] as String?,
    );
  }
}

/// A playlist from `getPlaylists`/`getPlaylist`/`createPlaylist` — the server's
/// stable [id] and its display [name].
///
/// Only the fields Linthra maps are kept. The ordered song entries of a playlist
/// arrive as `SubsonicSongDto`s under `getPlaylist`'s `entry` list and are read
/// separately; this DTO is just the playlist header.
class SubsonicPlaylistDto {
  const SubsonicPlaylistDto({required this.id, required this.name});

  final String id;
  final String name;

  /// Parses a playlist header, or `null` when it has no usable id — so a
  /// malformed entry is skipped rather than importing a nameless, unaddressable
  /// playlist. A missing name falls back to the id so the row is never blank.
  static SubsonicPlaylistDto? fromJson(Map<String, dynamic> json) {
    final String? id = json['id'] as String?;
    if (id == null || id.isEmpty) return null;
    final String? name = json['name'] as String?;
    return SubsonicPlaylistDto(
      id: id,
      name: name == null || name.isEmpty ? id : name,
    );
  }
}
