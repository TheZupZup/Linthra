/// Wire models for the Jellyfin REST API.
///
/// These mirror the JSON shapes the server returns and live behind
/// [JellyfinClient]; nothing outside the Jellyfin source should touch them.
/// Mapping them to Linthra's [Track]/[Album]/[Artist] is the
/// `JellyfinTrackMapper`'s job, keeping HTTP parsing and domain mapping
/// separate.
library;

import 'jellyfin_server_capabilities.dart';

/// Which kind of music item to list. Maps to a Jellyfin item type / endpoint
/// inside the client, so the source can ask for "tracks" without knowing the
/// query string.
enum JellyfinItemKind { audio, album, artist }

/// A playback lifecycle event reported to Jellyfin's play-session endpoints.
///
/// The client maps each value to the right endpoint and body: [started] posts
/// to `/Sessions/Playing`, [stopped] to `/Sessions/Playing/Stopped`, and the
/// middle three to `/Sessions/Playing/Progress` (with `IsPaused` telling the
/// server whether the player is paused). The reporter only ever picks an
/// event; how Jellyfin spells it on the wire stays inside the client.
enum JellyfinPlaybackEvent { started, progress, paused, resumed, stopped }

/// What a tiny pre-flight request to a minted stream URL observed.
///
/// The playback source probes the stream URL before handing it to the audio
/// engine so a Cloudflare page, an expired token, or a non-audio response
/// becomes a precise, friendly error instead of an opaque engine failure. Only
/// the (non-secret) HTTP status and content type are carried — never the URL or
/// the token woven into it. The classification getters keep the "is this
/// playable audio?" rules in one pure, testable place.
class JellyfinStreamProbe {
  const JellyfinStreamProbe({required this.statusCode, this.contentType});

  /// The HTTP status the probe saw (after following any redirects).
  final int statusCode;

  /// The response's `Content-Type`, when present (parameters like `; charset`
  /// are ignored by the classifiers below).
  final String? contentType;

  /// A 2xx response (covers `206 Partial Content` from the ranged probe).
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// The server answered with an HTML page — a Cloudflare challenge/block, a
  /// login page, or a reverse-proxy error page — where audio was expected.
  bool get isHtml {
    final String? type = _mimeType;
    return type != null && type.startsWith('text/html');
  }

  /// The body looks like something the audio engine can open: an `audio/*`
  /// type, the generic binary `application/octet-stream` some servers use for
  /// media, or a missing content type (lenient — the engine sniffs the
  /// container itself, and a 2xx with bytes is almost certainly the file).
  bool get isAudio {
    final String? type = _mimeType;
    if (type == null) return true;
    return type.startsWith('audio/') ||
        type.startsWith('video/') ||
        type == 'application/octet-stream';
  }

  /// The bare MIME type, lower-cased and without parameters.
  String? get _mimeType {
    final String? raw = contentType;
    if (raw == null) return null;
    final String type = raw.split(';').first.trim().toLowerCase();
    return type.isEmpty ? null : type;
  }
}

/// Public server info from `GET /System/Info/Public` — enough to confirm the
/// address is a Jellyfin server, to show the user which one they reached, and to
/// record the server's version/product for compatibility and diagnostics.
///
/// The extra fields ([productName], [operatingSystem]) are optional because
/// Jellyfin only includes them on some versions; they're used for display and
/// the diagnostics report, never to branch request behavior.
class JellyfinServerInfo {
  const JellyfinServerInfo({
    required this.serverName,
    required this.version,
    this.id,
    this.productName,
    this.operatingSystem,
  });

  final String serverName;
  final String version;
  final String? id;

  /// The server's product name (e.g. `Jellyfin Server`), when reported.
  final String? productName;

  /// The host OS the server reports, when present (often absent in the public
  /// info on locked-down servers).
  final String? operatingSystem;

  /// The reported [version] parsed into a comparable value, or `null` when it
  /// has no recognizable `major.minor`.
  JellyfinServerVersion? get parsedVersion =>
      JellyfinServerVersion.tryParse(version);

  /// How well Linthra expects to work with this server's version. Diagnostic
  /// only — see [jellyfinServerSupportFor].
  JellyfinServerSupport get support => jellyfinServerSupportFor(version);

  /// Parses the response, or returns `null` when the body lacks the fields a
  /// real Jellyfin server always sends (so the client can report "not a
  /// Jellyfin server" instead of surfacing a half-empty object).
  ///
  /// Every field is read through [_coerceString], so a server that sends a
  /// required field with an unexpected type (a numeric `Version`, say) reads as
  /// absent — a clean "not a Jellyfin server" — rather than throwing a
  /// `TypeError` that would crash Test-connection / version detection. The
  /// optional fields simply degrade to `null`.
  static JellyfinServerInfo? fromJson(Map<String, dynamic> json) {
    final String? name = _coerceString(json['ServerName']);
    final String? version = _coerceString(json['Version']);
    if (name == null || version == null) return null;
    return JellyfinServerInfo(
      serverName: name,
      version: version,
      id: _coerceString(json['Id']),
      productName: _coerceString(json['ProductName']),
      operatingSystem: _coerceString(json['OperatingSystem']),
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
  /// or the wrong type (an unexpected body) so the client can fail clearly with
  /// a sign-in error rather than throw a `TypeError`. Every field is read
  /// through [_coerceString], which already rejects empty/whitespace, so a
  /// blank token or user id is treated as absent.
  static JellyfinAuthResult? fromJson(Map<String, dynamic> json) {
    final String? token = _coerceString(json['AccessToken']);
    final Object? user = json['User'];
    final String? userId =
        user is Map<String, dynamic> ? _coerceString(user['Id']) : null;
    if (token == null || userId == null) {
      return null;
    }
    return JellyfinAuthResult(
      accessToken: token,
      userId: userId,
      userName:
          user is Map<String, dynamic> ? _coerceString(user['Name']) : null,
      serverId: _coerceString(json['ServerId']),
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

  /// Parses one item, or returns `null` when it lacks a usable id/name (skipped
  /// by the caller) so a single malformed entry can't break a whole listing.
  ///
  /// Tolerant by construction: every optional field is read through a *coercing*
  /// helper ([_coerceString], [_coerceInt], [_coerceStringList]) rather than a
  /// raw `as` cast, so a weird server that sends a number where a string is
  /// expected (or vice versa) yields a safe fallback (`null`/empty) for that one
  /// field instead of throwing a `TypeError` that would abort the whole sync.
  /// Only a missing or blank id/name — an item Linthra cannot reference or
  /// label — is rejected.
  static JellyfinItemDto? fromJson(Map<String, dynamic> json) {
    final String? id = _coerceString(json['Id']);
    final String? name = _coerceString(json['Name']);
    if (id == null || name == null) return null;

    final Object? imageTags = json['ImageTags'];
    final bool hasPrimary = imageTags is Map && imageTags['Primary'] != null;

    return JellyfinItemDto(
      id: id,
      name: name,
      album: _coerceString(json['Album']),
      albumId: _coerceString(json['AlbumId']),
      albumArtist: _coerceString(json['AlbumArtist']),
      artists: _coerceStringList(json['Artists']),
      runTimeTicks: _coerceInt(json['RunTimeTicks']),
      indexNumber: _coerceInt(json['IndexNumber']),
      productionYear: _coerceInt(json['ProductionYear']),
      childCount: _coerceInt(json['ChildCount']),
      hasPrimaryImage: hasPrimary,
    );
  }
}

/// Shared, tolerant coercions for the wire values every DTO in this file reads.
///
/// Jellyfin 12 (and the occasional proxy or plugin) can send a field with an
/// unexpected type — a number where a string is expected, a numeric string for
/// a count — or omit it entirely. Reading every field through these coercions,
/// rather than a raw `as` cast, means such a value yields a safe fallback for
/// that one field instead of throwing a `TypeError` that would abort parsing an
/// entire response. The rule across the app: missing / renamed / null / retyped
/// fields are non-fatal. Proven first on [JellyfinItemDto] (PR #253) and hoisted
/// here so the server-info, auth, and playlist DTOs are equally robust.

/// A trimmed non-empty [String] from a wire value, or `null` for anything
/// else (a number, bool, list, missing, or blank). Trimming means a field
/// that is all whitespace reads as absent rather than a blank label.
String? _coerceString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// An [int] from a wire value, accepting the JSON `num` Jellyfin normally
/// sends *and* a numeric string some plugins/proxies emit. Returns `null` for
/// anything non-numeric (a non-number string, bool, list, …) so one weird
/// field never throws.
int? _coerceInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final String trimmed = value.trim();
    // Symmetric with the `num` path: a fractional numeric string ("123.9")
    // truncates exactly like the JSON number 123.9 would, rather than being
    // dropped because `int.tryParse` rejects the decimal point.
    return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt();
  }
  return null;
}

/// The non-empty strings from a wire list, or an empty list when the value
/// isn't a list at all. Non-string entries inside the list are dropped rather
/// than throwing, so a partially malformed `Artists` array still yields the
/// good names.
List<String> _coerceStringList(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final Object? entry in value)
      if (entry is String && entry.trim().isNotEmpty) entry.trim(),
  ];
}

/// The outcome of listing one [JellyfinItemKind] from the server: the items
/// that parsed cleanly, plus how many wire entries were **skipped** because
/// they were too malformed to use (missing id/name, or not an object).
///
/// Carrying [skippedCount] alongside the items lets a sync stay tolerant —
/// drop the bad entries rather than fail — while still telling the user, calmly,
/// that "some items could not be synced". It is a plain count, never the raw
/// entries, so nothing sensitive rides along.
class JellyfinItemListing {
  const JellyfinItemListing({
    required this.items,
    this.skippedCount = 0,
  });

  /// An empty listing (nothing fetched, nothing skipped) — the "valid but empty
  /// library" outcome a missing `Items` array maps to.
  static const JellyfinItemListing empty =
      JellyfinItemListing(items: <JellyfinItemDto>[]);

  /// The items that parsed into a usable DTO, in server order.
  final List<JellyfinItemDto> items;

  /// How many wire entries were dropped as unparseable across every page.
  final int skippedCount;
}

/// A playlist item from `GET /Users/<userId>/Items?IncludeItemTypes=Playlist`.
///
/// Only the fields Linthra mirrors are kept: the server playlist [id] (used as
/// the local playlist's `remoteId`) and its [name]. No token or URL is carried.
class JellyfinPlaylistDto {
  const JellyfinPlaylistDto({required this.id, required this.name});

  final String id;
  final String name;

  /// Parses one playlist entry, or `null` when it lacks a usable id/name (or
  /// sends either with the wrong type) so a single malformed entry is skipped
  /// by the caller rather than throwing a `TypeError` that aborts the whole
  /// playlist listing. Both fields are read through [_coerceString].
  static JellyfinPlaylistDto? fromJson(Map<String, dynamic> json) {
    final String? id = _coerceString(json['Id']);
    final String? name = _coerceString(json['Name']);
    if (id == null || name == null) return null;
    return JellyfinPlaylistDto(id: id, name: name);
  }
}

/// One entry inside a Jellyfin playlist, from `GET /Playlists/<id>/Items`.
///
/// Carries both the underlying media [itemId] (what Linthra stores as a track
/// reference) and the playlist-scoped [playlistItemId] (the *entry* id Jellyfin
/// requires to remove that entry — distinct from the media id). The entry id is
/// optional because some server versions omit it; removal falls back to a
/// no-entry-id outcome the caller can treat as "couldn't remove on server".
class JellyfinPlaylistEntry {
  const JellyfinPlaylistEntry({required this.itemId, this.playlistItemId});

  final String itemId;
  final String? playlistItemId;

  static JellyfinPlaylistEntry? fromJson(Map<String, dynamic> json) {
    final String? id = _coerceString(json['Id']);
    if (id == null) return null;
    return JellyfinPlaylistEntry(
      itemId: id,
      playlistItemId: _coerceString(json['PlaylistItemId']),
    );
  }
}
