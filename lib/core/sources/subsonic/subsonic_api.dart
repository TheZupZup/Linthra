/// Wire models for the Subsonic REST API (and OpenSubsonic extensions).
///
/// These mirror the JSON shapes a Subsonic-compatible server (such as
/// Navidrome) returns and live behind [SubsonicClient]; nothing outside the
/// Subsonic source should touch them. Mapping them to Linthra's
/// [Track]/[Album]/[Artist] is the `SubsonicTrackMapper`'s job, keeping HTTP
/// parsing and domain mapping separate.
///
/// Only the fields Linthra maps today are kept; the rest of each (large) item
/// payload is ignored. The Rust core reads them out of a server's answer
/// (native/linthra_core/src/subsonic/response.rs, through `subsonic_reply.dart`).
library;

import '../media_content_type.dart';

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
    this.dateCreated,
    this.coverArt,
  });

  final String id;
  final String name;
  final String? artist;
  final int songCount;
  final int? year;

  ///The album's creation date from the server.
  final DateTime? dateCreated;

  /// The server's cover-art id for this album, when present. An opaque handle
  /// (e.g. `al-123`) the `getCoverArt` endpoint resolves to an image — not a
  /// URL and not a credential. Maps to the album's artwork.
  final String? coverArt;
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
    this.dateCreated,
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

  /// The date when this song was added to the server.
  final DateTime? dateCreated;

  /// The server's cover-art id for this song, when present. An opaque handle
  /// (typically the album's, e.g. `al-123`, or the song's own `mf-123`) the
  /// `getCoverArt` endpoint resolves to an image — not a URL and not a
  /// credential. Maps to the track's artwork.
  final String? coverArt;
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
}
