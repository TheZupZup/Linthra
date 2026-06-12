import 'plex_api.dart';

/// Every Plex Media Server REST path and URL Linthra builds, in one place.
///
/// Centralizing the endpoints means:
///  - the (future) HTTP client, music source, and track mapper never embed raw
///    path strings, so a path can't quietly drift between two call sites;
///  - the exact set of endpoints Linthra depends on is auditable from this one
///    file (kept in sync with docs/plex.md);
///  - the token-bearing stream and cover-art URLs are built by the same pure,
///    tested helpers, so the "weave the token into the query, on demand, never
///    store it" rule — and the matching redaction — live in a single spot.
///
/// All builders are pure: they take a clean base URL (no trailing slash) plus
/// the ids/params they need and return a [Uri]. Nothing here performs I/O,
/// holds state, or logs.
///
/// **Where the token rides (Plex's key difference).** API calls
/// ([identity], [librarySections], [sectionItems], [metadata]) carry the
/// `X-Plex-Token` in a *request header*, set by the client — so those builders
/// take **no token** and emit token-free URLs safe to log. Only the
/// stream/cover-art URLs ([streamUrl], [coverArt]) are handed to the audio/image
/// layers, which can't set headers, so they must carry the token as a **query
/// param** — a bigger leak surface. Those two builders are the *only* place a
/// token enters a Plex URL, and [redactToken] is the matching guard for any code
/// that logs one. See docs/plex.md → Token safety rules.
abstract final class PlexEndpoints {
  // --- Path templates: the only place these strings are written. ---
  static const String _identityPath = '/identity';
  static const String _sectionsPath = '/library/sections';
  static const String _metadataPath = '/library/metadata';
  static const String _timelinePath = '/:/timeline';

  // --- Query-parameter keys, named once so a typo can't split a request. ---

  /// The Plex auth token. Carried in the query of **stream/cover-art** URLs only
  /// (the audio/image layers can't set a header); API calls send it as the
  /// `X-Plex-Token` *header* instead, so it never reaches a logged API URL.
  static const String tokenParam = 'X-Plex-Token';

  /// The numeric metadata `type` selector for a section listing (8/9/10).
  static const String typeParam = 'type';

  /// Pagination: the zero-based index of the first item to return.
  static const String containerStartParam = 'X-Plex-Container-Start';

  /// Pagination: the maximum number of items to return in one page.
  static const String containerSizeParam = 'X-Plex-Container-Size';

  // --- Timeline (playback reporting) query keys; see [timeline]. ---

  /// The reported item's stable per-server id.
  static const String ratingKeyParam = 'ratingKey';

  /// The reported item's metadata path (`/library/metadata/{ratingKey}`).
  static const String keyParam = 'key';

  /// The playback state being reported (a [PlexTimelineState] value).
  static const String stateParam = 'state';

  /// The playback position, in **milliseconds**.
  static const String timeParam = 'time';

  /// The item duration, in **milliseconds**.
  static const String durationParam = 'duration';

  /// The metadata-provider identifier PMS expects on a timeline report. Every
  /// library item PMS serves belongs to this built-in provider, so the value
  /// is a fixed protocol constant (the same one the official clients and
  /// python-plexapi send), not anything per-user or secret.
  static const String identifierParam = 'identifier';
  static const String libraryIdentifier = 'com.plexapp.plugins.library';

  /// `GET /identity` — server identity / reachability (`machineIdentifier`,
  /// version). Token-free path; the client adds the `X-Plex-Token` header.
  /// Mirrors Jellyfin `/System/Info/Public` and Subsonic `ping`.
  static Uri identity(String baseUrl) => _join(baseUrl, _identityPath);

  /// `GET /library/sections` — the library sections (`Directory` entries).
  /// Linthra keeps the music ones ([PlexDirectory.isMusic]).
  static Uri librarySections(String baseUrl) => _join(baseUrl, _sectionsPath);

  /// `GET /library/sections/{key}/all?type=…` — one page of a music section's
  /// items of the given [itemType] (artist 8 / album 9 / track 10).
  ///
  /// Pagination is opt-in: pass [start] and/or [size] to add the
  /// `X-Plex-Container-Start` / `X-Plex-Container-Size` query params and walk a
  /// large library page by page (reusing the paged-walk shape Subsonic uses);
  /// omit them to let PMS return its default first page. The token is **not**
  /// added here — it rides in the client's request header.
  static Uri sectionItems(
    String baseUrl, {
    required String sectionKey,
    required PlexMetadataType itemType,
    int? start,
    int? size,
  }) {
    final Map<String, String> query = <String, String>{
      typeParam: '${itemType.value}',
      if (start != null) containerStartParam: '$start',
      if (size != null) containerSizeParam: '$size',
    };
    return _join(baseUrl, '$_sectionsPath/$sectionKey/all')
        .replace(queryParameters: query);
  }

  /// `GET /library/metadata/{ratingKey}` — a single item with its `Media`/`Part`
  /// entries. The play-time lookup that turns an opaque `plex:<ratingKey>` into a
  /// playable [PlexPart.key], because the Part key differs from the `ratingKey`.
  /// Token-free path; the client adds the `X-Plex-Token` header.
  static Uri metadata(String baseUrl, {required String ratingKey}) =>
      _join(baseUrl, '$_metadataPath/$ratingKey');

  /// `GET /:/timeline?ratingKey=…&key=…&state=…&time=…` — reports playback of
  /// one item back to PMS, which is what makes the client appear in (and
  /// update / leave) the server's Now Playing dashboard.
  ///
  /// [timeMs] is the playback position and [durationMs] the item length, both
  /// in **milliseconds** (the unit PMS uses everywhere; omit [durationMs] when
  /// unknown rather than reporting a fake zero). The `key` is derived from the
  /// [ratingKey] (`/library/metadata/{ratingKey}`), and `identifier` is the
  /// fixed library-provider constant — neither is a credential. Like every
  /// API call (and unlike the stream/art URLs), the token is **not** woven in
  /// here: it rides in the client's `X-Plex-Token` header, so a timeline URL
  /// is token-free, safe to log, and never worth persisting.
  static Uri timeline(
    String baseUrl, {
    required String ratingKey,
    required PlexTimelineState state,
    required int timeMs,
    int? durationMs,
  }) {
    return _join(baseUrl, _timelinePath).replace(
      queryParameters: <String, String>{
        ratingKeyParam: ratingKey,
        keyParam: '$_metadataPath/$ratingKey',
        identifierParam: libraryIdentifier,
        stateParam: state.value,
        timeParam: '$timeMs',
        if (durationMs != null) durationParam: '$durationMs',
      },
    );
  }

  /// The direct-play stream URL for a track: `{baseUrl}{partKey}?X-Plex-Token=…`.
  ///
  /// [partKey] is the `Media[0].Part[0].key` *path* read from a metadata lookup
  /// (e.g. `/library/parts/12345/…/file.flac`) — already server-absolute, so it
  /// is appended to [baseUrl] as-is. Phase 1 is direct-play only (no
  /// transcoder). Unlike the API calls, this URL is fetched by the audio engine,
  /// which can't set headers, so the [token] is woven into the **query** here,
  /// on demand, and never stored on a [Track] or in the catalog.
  static Uri streamUrl(
    String baseUrl, {
    required String partKey,
    required String token,
  }) =>
      _withToken(_join(baseUrl, partKey), token);

  /// The cover-art URL for an item's `thumb` path:
  /// `{baseUrl}{thumbPath}?X-Plex-Token=…`.
  ///
  /// [thumbPath] is the server-absolute `thumb` path an item reports (e.g.
  /// `/library/metadata/123/thumb/167…`). Like [streamUrl], the image is fetched
  /// plainly (no headers), so the [token] rides in the query — woven in here, on
  /// demand at render time, and never persisted (the catalog stores only a
  /// credential-free `plex-thumb:` reference).
  static Uri coverArt(
    String baseUrl, {
    required String thumbPath,
    required String token,
  }) =>
      _withToken(_join(baseUrl, thumbPath), token);

  /// [url] with the live session [token] woven into its query, **preserving**
  /// any query the path already carried — a thumb can legitimately be a sizing
  /// transcoder path (`/photo/:/transcode?url=…&width=…`), and replacing the
  /// whole query would silently strip those params and break the request.
  ///
  /// The existing pairs are spliced through **raw** (from `Uri.query`), never
  /// decoded and re-encoded: a transcoder's `url=` value is itself
  /// percent-encoded, and a decode/re-encode cycle would normalize its bytes
  /// (e.g. `%20` ↔ `+`), handing the server a query it never wrote. Splitting
  /// on `&` is sound on the raw form — an encoded value's own `&` is still
  /// `%26` there.
  ///
  /// Any pair already *naming* the token (however cased or percent-encoded) is
  /// dropped first: the live session's token is the only credential allowed
  /// into a minted URL, so a stored path can never smuggle one in (or pin a
  /// stale one) past the "mint on demand, never persist" rule.
  static Uri _withToken(Uri url, String token) {
    final StringBuffer query = StringBuffer();
    for (final String pair in url.query.split('&')) {
      if (pair.isEmpty || _namesToken(pair)) continue;
      if (query.isNotEmpty) query.write('&');
      query.write(pair);
    }
    if (query.isNotEmpty) query.write('&');
    query.write('$tokenParam=${Uri.encodeQueryComponent(token)}');
    return url.replace(query: query.toString());
  }

  /// Whether a raw `key=value` query [pair] names the token parameter, however
  /// the key is cased or percent-encoded — so a smuggled credential can't dodge
  /// [_withToken]'s filter by encoding a letter of its name. A key that fails
  /// to decode (not producible by a parsed [Uri], which normalizes invalid
  /// escapes) is kept as an ordinary pair: it can't *be* the token name.
  static bool _namesToken(String pair) {
    final int equals = pair.indexOf('=');
    final String rawKey = equals < 0 ? pair : pair.substring(0, equals);
    try {
      return Uri.decodeQueryComponent(rawKey).toLowerCase() ==
          tokenParam.toLowerCase();
    } on ArgumentError {
      // decodeQueryComponent rejects an invalid escape with an ArgumentError.
      return false;
    } on FormatException {
      return false;
    }
  }

  /// Replaces every `X-Plex-Token=<value>` in [text] with
  /// `X-Plex-Token=<redacted>`, so a stream/art URL (or any line carrying one)
  /// can be logged or surfaced without leaking the token.
  ///
  /// Because the token rides in stream/art **query params**, a single
  /// unguarded URL log line would expose the whole token — so anything that logs
  /// a Plex URL must pass it through here first. Pure and case-insensitive on
  /// the parameter name; the value runs up to the next `&`, `#`, whitespace, or
  /// end of string.
  static String redactToken(String text) =>
      text.replaceAll(_tokenPattern, '$tokenParam=<redacted>');

  static final RegExp _tokenPattern =
      RegExp('$tokenParam=[^&#\\s]*', caseSensitive: false);

  static Uri _join(String baseUrl, String path) => Uri.parse('$baseUrl$path');
}
