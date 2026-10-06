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

import '../media_content_type.dart';

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
      errorCode: error is Map<String, dynamic> ? _asInt(error['code']) : null,
      errorMessage:
          error is Map<String, dynamic> ? _asString(error['message']) : null,
      version: _asString(raw['version']),
      type: _asString(raw['type']),
      serverVersion: _asString(raw['serverVersion']),
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

  /// The body looks like something the audio engine can open: anything that
  /// isn't plainly a document ([MediaContentType.isDocument]), a missing type
  /// included. Servers label media inconsistently: a Go server with no system
  /// mime table sniffs an Ogg or Opus file as `application/ogg`, and object
  /// storage gives `binary/octet-stream`. The engine sniffs the container
  /// itself, so only a document (an error envelope, a login page) is refused.
  /// It is the same rule downloads and the cast relay apply, so a track the
  /// app will download is never one it refuses to stream.
  bool get isAudio => !MediaContentType.isDocument(contentType);

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
    final String? id = _asString(json['id']);
    final String? name = _asString(json['name']);
    if (id == null || id.isEmpty || name == null) return null;
    return SubsonicArtistDto(
      id: id,
      name: name,
      albumCount: _asInt(json['albumCount']) ?? 0,
      coverArt: _asString(json['coverArt']),
    );
  }
}

/// One page of `getAlbumList2`: the albums that mapped, plus how many entries
/// the server actually returned.
class SubsonicAlbumPage {
  const SubsonicAlbumPage({required this.albums, required this.entryCount});

  final List<SubsonicAlbumDto> albums;

  /// Every entry on the page, including any too malformed to map. Paging
  /// decides "this was the last page" on this count, never on [albums], so a
  /// skipped entry can't end a walk early and silently drop the rest.
  final int entryCount;
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
    final String? id = _asString(json['id']);
    final String? name = _asString(json['name']);
    if (id == null || id.isEmpty || name == null) return null;
    return SubsonicAlbumDto(
      id: id,
      name: name,
      artist: _asString(json['artist']),
      songCount: _asInt(json['songCount']) ?? 0,
      year: _asInt(json['year']),
      coverArt: _asString(json['coverArt']),
    );
  }
}

/// A song/track from `getAlbum` (an album's child list).
class SubsonicSongDto {
  const SubsonicSongDto({
    required this.id,
    required this.title,
    this.album,
    this.albumId,
    this.artist,
    this.track,
    this.durationSeconds,
    this.coverArt,
  });

  final String id;
  final String title;
  final String? album;

  /// The server's stable id for this song's album (the classic API's
  /// `albumId`, e.g. `al-27`), when present. Maps to the track's album id — no
  /// per-song "album artist" field exists in the classic (non-ID3) response
  /// this DTO reads, so that stays unset; see `SubsonicTrackMapper`.
  final String? albumId;

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
    final String? id = _asString(json['id']);
    final String? title = _asString(json['title']);
    if (id == null || id.isEmpty || title == null) return null;
    return SubsonicSongDto(
      id: id,
      title: title,
      album: _asString(json['album']),
      albumId: _asString(json['albumId']),
      artist: _asString(json['artist']),
      track: _asInt(json['track']),
      durationSeconds: _asInt(json['duration']),
      coverArt: _asString(json['coverArt']),
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
    final String? id = _asString(json['id']);
    if (id == null || id.isEmpty) return null;
    final String? name = _asString(json['name']);
    return SubsonicPlaylistDto(
      id: id,
      name: name == null || name.isEmpty ? id : name,
    );
  }
}

// The reads every parser above goes through, by the rule the Jellyfin DTOs
// already follow: a value of an unexpected type is left out rather than thrown
// on. A `TypeError` here would fail a whole sync over one odd record, and the
// next launch would walk the library into it again (#781).

/// [value] when it is a string, otherwise `null`.
String? _asString(Object? value) => value is String ? value : null;

/// A whole number from a JSON number or a numeric string, truncated the same
/// way for both. `null` for anything else, including a number too large to
/// be finite, which `toInt` would throw on.
int? _asInt(Object? value) {
  final num? number = switch (value) {
    num() => value,
    String() => num.tryParse(value.trim()),
    _ => null,
  };
  return number != null && number.isFinite ? number.toInt() : null;
}
