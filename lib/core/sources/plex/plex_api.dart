/// Wire models for the Plex Media Server HTTP API.
///
/// These mirror the JSON shapes a Plex Media Server (PMS) returns when asked for
/// JSON (`Accept: application/json`) and live behind the future `PlexClient`;
/// nothing outside the Plex source should touch them. Mapping them to Linthra's
/// [Track]/[Album]/[Artist] is the future `PlexTrackMapper`'s job, keeping HTTP
/// parsing and domain mapping separate — exactly as `JellyfinApi` /
/// `SubsonicApi` do.
///
/// **JSON-only (phase 1, intentional).** PMS defaults to XML and only returns
/// JSON when the client sends `Accept: application/json`. These parsers read
/// **JSON only**; XML is deliberately unsupported in phase 1 (the future client
/// sets the `Accept` header and maps a non-JSON body to a clear error). See
/// docs/plex.md → Risks.
///
/// **No credentials here.** None of these DTOs carry, parse, or hold an
/// `X-Plex-Token`. A Plex item's stable identity is its per-server `ratingKey`,
/// and a track's playable bytes live behind a [PlexPart.key] *path* — neither is
/// a credential, and the token is woven into a URL only at play/render time by
/// the URL builders in `plex_endpoints.dart`, never stored on a DTO. See
/// docs/plex.md → Token safety rules.
///
/// Only the fields Linthra maps today are kept; the rest of each (large) Plex
/// payload is ignored.
library;

/// Plex's numeric metadata `type` for the three music kinds Linthra lists.
///
/// PMS identifies music items by a numeric type both in the listing query
/// (`/library/sections/{key}/all?type=8`) and, as a string, on each item
/// (`"type": "artist"`). This enum is the one place that mapping lives, so the
/// endpoint builder and the (future) track mapper agree on 8 = artist,
/// 9 = album, 10 = track.
enum PlexMetadataType {
  artist(8, 'artist'),
  album(9, 'album'),
  track(10, 'track');

  const PlexMetadataType(this.value, this.typeName);

  /// The numeric `type` PMS expects in the listing query string.
  final int value;

  /// The string `type` PMS reports on each metadata item.
  final String typeName;

  /// The type for a metadata item's string `type` field (e.g. `"album"`), or
  /// `null` for anything that isn't one of the three music kinds.
  static PlexMetadataType? fromTypeName(String? name) {
    if (name == null) return null;
    for (final PlexMetadataType type in values) {
      if (type.typeName == name) return type;
    }
    return null;
  }
}

/// The playback state a client reports to PMS on the `/:/timeline` endpoint.
///
/// Mirrors [PlexMetadataType]: a request-side wire value named once, so the
/// endpoint builder, client, and reporter agree on the exact strings PMS
/// expects. PMS keys its Now Playing sessions off these reports: `playing` /
/// `paused` show (and update) the session, `stopped` clears it, and
/// `buffering` is accepted for an engine stall. (PMS also accepts `error`,
/// which Linthra deliberately never sends — a playback failure ends the
/// session, so it reports `stopped`.)
enum PlexTimelineState {
  playing('playing'),
  paused('paused'),
  stopped('stopped'),
  buffering('buffering');

  const PlexTimelineState(this.value);

  /// The literal `state` query value PMS expects.
  final String value;
}

/// Server identity from `GET /identity` — enough to confirm the address is a
/// Plex Media Server and to record its version for display and diagnostics.
///
/// Mirrors `JellyfinServerInfo` / `SubsonicServerInfo`: a successful parse means
/// "this really is a Plex server", so the future authenticator can report "not
/// a Plex server" instead of surfacing a half-empty object. The identity fields
/// live inside the `MediaContainer` envelope PMS wraps every response in.
class PlexServerIdentity {
  const PlexServerIdentity({required this.machineIdentifier, this.version});

  /// The stable per-server id PMS reports as `machineIdentifier`. Used to
  /// recognise the same server again; not a secret.
  final String machineIdentifier;

  /// The PMS version string, when reported (display/diagnostics only — never
  /// used to branch request behavior).
  final String? version;

  /// Parses the `/identity` body, or returns `null` when it lacks the
  /// `machineIdentifier` a real PMS always sends (so the caller can report "not
  /// a Plex server").
  static PlexServerIdentity? fromJson(Map<String, dynamic> json) {
    final Object? container = json['MediaContainer'];
    if (container is! Map<String, dynamic>) return null;
    final String? id = _asString(container['machineIdentifier']);
    if (id == null || id.isEmpty) return null;
    return PlexServerIdentity(
      machineIdentifier: id,
      version: _asString(container['version']),
    );
  }
}

/// The `MediaContainer` envelope every Plex listing endpoint wraps its payload
/// in (`/library/sections`, `/library/sections/{key}/all`, `/library/metadata`).
///
/// Carries the paging counters Linthra needs to walk a large library
/// ([totalSize] / [size] / [offset]) plus the two payload arrays: [directories]
/// (library sections) and [metadata] (artists/albums/tracks). A given response
/// uses one array or the other; the unused one is empty.
class PlexMediaContainer {
  const PlexMediaContainer({
    this.size,
    this.totalSize,
    this.offset,
    this.directories = const <PlexDirectory>[],
    this.metadata = const <PlexMetadata>[],
  });

  /// The number of items in *this* response page (PMS `size`).
  final int? size;

  /// The total number of items across all pages (PMS `totalSize`). PMS may omit
  /// it when the whole set fits in one response; [total] then falls back to
  /// [size]. This is the counter the paged walk compares against.
  final int? totalSize;

  /// The zero-based index of the first item in this page (PMS `offset`),
  /// echoing the requested `X-Plex-Container-Start`.
  final int? offset;

  /// Library sections from `GET /library/sections` (the `Directory` array).
  final List<PlexDirectory> directories;

  /// Music items from `GET /library/sections/{key}/all` or
  /// `GET /library/metadata/{ratingKey}` (the `Metadata` array).
  final List<PlexMetadata> metadata;

  /// The total item count for pagination: [totalSize] when PMS reports it, else
  /// [size] (a single-page response omits `totalSize`), else `null`.
  int? get total => totalSize ?? size;

  /// Parses the top-level body, or returns `null` when it isn't a
  /// `MediaContainer` envelope (so the client can report "not a Plex server"
  /// rather than surfacing a half-empty object). Malformed individual entries
  /// are skipped, so one bad item can't break a whole listing.
  static PlexMediaContainer? fromJson(Map<String, dynamic> json) {
    final Object? raw = json['MediaContainer'];
    if (raw is! Map<String, dynamic>) return null;

    final Object? rawDirectories = raw['Directory'];
    final List<PlexDirectory> directories = rawDirectories is List
        ? <PlexDirectory>[
            for (final Object? entry in rawDirectories)
              if (entry is Map<String, dynamic>)
                if (PlexDirectory.fromJson(entry) case final PlexDirectory d) d,
          ]
        : const <PlexDirectory>[];

    final Object? rawMetadata = raw['Metadata'];
    final List<PlexMetadata> metadata = rawMetadata is List
        ? <PlexMetadata>[
            for (final Object? entry in rawMetadata)
              if (entry is Map<String, dynamic>)
                if (PlexMetadata.fromJson(entry) case final PlexMetadata m) m,
          ]
        : const <PlexMetadata>[];

    return PlexMediaContainer(
      size: (raw['size'] as num?)?.toInt(),
      totalSize: (raw['totalSize'] as num?)?.toInt(),
      offset: (raw['offset'] as num?)?.toInt(),
      directories: directories,
      metadata: metadata,
    );
  }
}

/// A library section (`Directory`) from `GET /library/sections`.
///
/// Linthra keeps the music sections — those whose `type` is `"artist"` (PMS
/// labels a music library by its top-level item type) — and lets the user pick
/// which to include. The [key] is the section id used in the listing path
/// (`/library/sections/{key}/all`); it is **not** a credential.
class PlexDirectory {
  const PlexDirectory({
    required this.key,
    required this.title,
    this.type,
    this.uuid,
  });

  /// The section id used to build its listing path. A short server-local
  /// identifier (e.g. `"3"`), not a secret.
  final String key;

  final String title;

  /// The section's content type (`"artist"` for a music library, `"movie"`,
  /// `"show"`, …), when reported.
  final String? type;

  /// The section's stable UUID, when reported.
  final String? uuid;

  /// Whether this is a music library (PMS types a music section as `artist`).
  bool get isMusic => type == 'artist';

  /// Parses one section, or returns `null` when it lacks a key/title so a single
  /// malformed entry can't break the sections listing.
  static PlexDirectory? fromJson(Map<String, dynamic> json) {
    final String? key = _asString(json['key']);
    final String? title = _asString(json['title']);
    if (key == null || key.isEmpty || title == null) return null;
    return PlexDirectory(
      key: key,
      title: title,
      type: _asString(json['type']),
      uuid: _asString(json['uuid']),
    );
  }
}

/// A single music item (artist, album, or track) from a `Metadata` array.
///
/// One DTO covers all three kinds; [type] (and [metadataType]) says which.
/// Album and track items carry their parent/grandparent links so the mapper can
/// fill artist/album names without a second request:
///  - an **album** (`type` 9) has [parentRatingKey] → its artist;
///  - a **track** (`type` 10) has [parentRatingKey] → its album and
///    [grandparentRatingKey] → its artist.
///
/// The stable per-server [ratingKey] is the item's identity (and the basis for
/// the opaque `plex:<ratingKey>` track URI a later PR mints) — it is **not** the
/// playable [PlexPart.key] and carries no credential.
class PlexMetadata {
  const PlexMetadata({
    required this.ratingKey,
    this.type,
    this.title,
    this.parentRatingKey,
    this.grandparentRatingKey,
    this.parentTitle,
    this.grandparentTitle,
    this.thumb,
    this.duration,
    this.index,
    this.year,
    this.leafCount,
    this.media = const <PlexMedia>[],
  });

  /// The stable per-server id PMS assigns this item. Identity only — never a
  /// file path and never a credential.
  final String ratingKey;

  /// The item's string `type` (`"artist"`, `"album"`, `"track"`), when present.
  final String? type;

  final String? title;

  /// For an album: its artist's `ratingKey`. For a track: its album's. `null`
  /// for an artist (or when PMS omits it).
  final String? parentRatingKey;

  /// For a track: its artist's `ratingKey`. `null` for albums/artists.
  final String? grandparentRatingKey;

  /// The parent's title (an album's artist name, a track's album name), when
  /// reported — a free fallback so the mapper needn't refetch the parent.
  final String? parentTitle;

  /// The grandparent's title (a track's artist name), when reported.
  final String? grandparentTitle;

  /// The item's cover-art *path* (e.g. `/library/metadata/123/thumb/167…`), when
  /// present. A path, not a URL: the token is woven in only at render time by
  /// [PlexEndpoints.coverArt], and the catalog stores a credential-free
  /// `plex-thumb:` reference (a later PR), never this turned into a tokened URL.
  final String? thumb;

  /// Duration in **milliseconds**, when reported (PMS reports track length in
  /// ms, unlike Subsonic's whole seconds or Jellyfin's 100-ns ticks).
  final int? duration;

  /// A track's **track number** within its album (PMS `index`), when reported;
  /// `null` for an artist/album or a track PMS doesn't number. Plex reports the
  /// **disc** number separately as `parentIndex`, which Linthra's [Track] model
  /// has no field for, so it is intentionally not parsed (a disc field would be
  /// a shared-model + schema change neither Jellyfin nor Subsonic carry).
  final int? index;

  /// An album's release **year** (PMS `year`), when reported; `null` otherwise.
  final int? year;

  /// An album's **track count** (PMS `leafCount` — the number of tracks under
  /// it), when reported; `null` otherwise.
  final int? leafCount;

  /// The item's `Media` entries (present on tracks; an album/artist listing
  /// omits them). Each holds the [PlexPart]s whose [PlexPart.key] is the actual
  /// stream path resolved at play time.
  final List<PlexMedia> media;

  /// The strongly-typed music kind for [type], or `null` when this item isn't
  /// one of artist/album/track.
  PlexMetadataType? get metadataType => PlexMetadataType.fromTypeName(type);

  /// The stream path of the first available [PlexPart], or `null` when the item
  /// carries no media (e.g. an album/artist listing entry).
  ///
  /// This is the `Media[0].Part[0].key` the documented two-step play resolution
  /// reads after a `GET /library/metadata/{ratingKey}` — a *path*, fed to
  /// [PlexEndpoints.streamUrl] with the token at play time, never persisted.
  String? get firstPartKey {
    for (final PlexMedia m in media) {
      for (final PlexPart part in m.parts) {
        return part.key;
      }
    }
    return null;
  }

  /// Parses one item, or returns `null` when it lacks a [ratingKey] (its stable
  /// identity) so a single malformed entry can't break a whole listing. A
  /// missing title is tolerated (kept `null`); the mapper supplies a fallback.
  static PlexMetadata? fromJson(Map<String, dynamic> json) {
    final String? ratingKey = _asString(json['ratingKey']);
    if (ratingKey == null || ratingKey.isEmpty) return null;

    final Object? rawMedia = json['Media'];
    final List<PlexMedia> media = rawMedia is List
        ? <PlexMedia>[
            for (final Object? entry in rawMedia)
              if (entry is Map<String, dynamic>) PlexMedia.fromJson(entry),
          ]
        : const <PlexMedia>[];

    return PlexMetadata(
      ratingKey: ratingKey,
      type: _asString(json['type']),
      title: _asString(json['title']),
      parentRatingKey: _asString(json['parentRatingKey']),
      grandparentRatingKey: _asString(json['grandparentRatingKey']),
      parentTitle: _asString(json['parentTitle']),
      grandparentTitle: _asString(json['grandparentTitle']),
      thumb: _asString(json['thumb']),
      duration: (json['duration'] as num?)?.toInt(),
      index: (json['index'] as num?)?.toInt(),
      year: (json['year'] as num?)?.toInt(),
      leafCount: (json['leafCount'] as num?)?.toInt(),
      media: media,
    );
  }
}

/// A `Media` entry on a track — a single playable rendition, holding the
/// [PlexPart]s that carry the actual file paths.
///
/// Phase 1 is direct-play only, so Linthra reads the first part's path and hands
/// it (with the token) to the audio engine; the transcoder is out of scope.
class PlexMedia {
  const PlexMedia({this.container, this.parts = const <PlexPart>[]});

  /// The rendition's container format (e.g. `"flac"`), when reported. Display /
  /// codec-fit only.
  final String? container;

  final List<PlexPart> parts;

  /// Parses one `Media` entry. Malformed parts are skipped; a media with no
  /// usable part yields an empty [parts] (the caller treats it as not playable).
  static PlexMedia fromJson(Map<String, dynamic> json) {
    final Object? rawParts = json['Part'];
    final List<PlexPart> parts = rawParts is List
        ? <PlexPart>[
            for (final Object? entry in rawParts)
              if (entry is Map<String, dynamic>)
                if (PlexPart.fromJson(entry) case final PlexPart p) p,
          ]
        : const <PlexPart>[];
    return PlexMedia(
      container: _asString(json['container']),
      parts: parts,
    );
  }
}

/// A `Part` of a [PlexMedia] — one physical file, whose [key] is the path the
/// stream URL is built from.
///
/// The Part [key] (e.g. `/library/parts/12345/…/file.flac`) is **not** the
/// item's `ratingKey`, which is exactly why a track's playable URL needs a
/// `GET /library/metadata/{ratingKey}` lookup at play time. The key is a path,
/// not a credential; the token is added only by [PlexEndpoints.streamUrl] when
/// the URL is minted, and that tokened URL is never persisted.
class PlexPart {
  const PlexPart({required this.key, this.container, this.duration});

  /// The stream path for this file. A server path, not a credential.
  final String key;

  /// The file's container format (e.g. `"flac"`), when reported.
  final String? container;

  /// Duration in milliseconds, when reported.
  final int? duration;

  /// Parses one part, or returns `null` when it lacks a [key] (without which it
  /// can't be streamed) so a malformed part is skipped rather than half-built.
  static PlexPart? fromJson(Map<String, dynamic> json) {
    final String? key = _asString(json['key']);
    if (key == null || key.isEmpty) return null;
    return PlexPart(
      key: key,
      container: _asString(json['container']),
      duration: (json['duration'] as num?)?.toInt(),
    );
  }
}

/// Reads a field that PMS may report as either a JSON string or a number
/// (`ratingKey`, `key`, and friends are usually strings but some servers/fields
/// emit bare numbers), returning a `String?` either way. Returns `null` for any
/// other type so a malformed value is treated as "absent".
String? _asString(Object? value) {
  if (value is String) return value;
  if (value is num) return value.toString();
  return null;
}
