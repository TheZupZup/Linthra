import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/lyrics.dart';
import '../../services/lyrics_text_parser.dart';
import 'plex_api.dart';
import 'plex_client.dart';
import 'plex_endpoints.dart';
import 'plex_exception.dart';

/// The real [PlexClient], backed by `package:http`.
///
/// The only file in the app that talks to a Plex Media Server over HTTP: it sets
/// the `Accept: application/json` header (Plex defaults to XML — see
/// docs/plex.md → Risks), the `X-Plex-Token` header, the [PlexClientIdentity]
/// headers, and parses the JSON `MediaContainer` envelope. The token-bearing
/// stream/art URLs are built elsewhere ([PlexEndpoints]); the API calls here
/// keep the token in a header, so the URLs they build are token-free and safe to
/// log.
///
/// Large `MediaContainer` listings are decoded **off the UI isolate**: a library
/// scan's `jsonDecode` + envelope parse of a big page is the heaviest
/// synchronous step in the whole flow, and running it inline froze the UI (and
/// triggered "app not responding") on 1000+-track libraries. Bodies at or above
/// [_backgroundParseThreshold] are parsed via `compute` on a background isolate;
/// small bodies (identity, a single item, a short page) stay inline to avoid the
/// isolate-spawn overhead.
///
/// Every failure becomes a [PlexException]; the token is never written into an
/// exception, a log, or any other output, so a leaked error string can't expose
/// it. Transport errors are classified from the low-level failure but only the
/// static, secret-free factory messages are ever thrown.
class HttpPlexClient implements PlexClient {
  HttpPlexClient({
    required PlexClientIdentity identity,
    http.Client? httpClient,
    int pageSize = _defaultPageSize,
    int backgroundParseThreshold = _defaultBackgroundParseThreshold,
    @visibleForTesting
    Future<PlexMediaContainer?> Function(Uint8List bytes)? backgroundParser,
  })  : assert(pageSize > 0, 'pageSize must be positive'),
        assert(backgroundParseThreshold >= 0,
            'backgroundParseThreshold must not be negative'),
        _identity = identity,
        _pageSize = pageSize,
        _backgroundParseThreshold = backgroundParseThreshold,
        _backgroundParser = backgroundParser ?? _computeParseContainer,
        _client = httpClient ?? http.Client();

  final PlexClientIdentity _identity;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  /// A page is requested this large; large libraries are walked page by page.
  /// Overridable via the constructor (mainly so tests can exercise the paged
  /// walk without 200-item fixtures).
  static const int _defaultPageSize = 200;
  final int _pageSize;

  /// A `MediaContainer` body at least this many bytes is decoded on a background
  /// isolate; smaller ones are decoded inline. 64 KiB comfortably clears tiny
  /// replies (identity, a single item) while catching full library pages, whose
  /// synchronous decode is what stalled the UI. Overridable for tests.
  static const int _defaultBackgroundParseThreshold = 64 * 1024;
  final int _backgroundParseThreshold;

  /// Decodes a large `MediaContainer` body into a [PlexMediaContainer]
  /// (`null` on a non-Plex/non-JSON body). Defaults to a `compute` call so the
  /// heavy parse runs off the UI isolate; injectable so a test can prove the
  /// large-body path is taken without spawning a real isolate.
  final Future<PlexMediaContainer?> Function(Uint8List bytes) _backgroundParser;

  /// A generous page-count cap stops a runaway loop if a server ever ignores the
  /// `X-Plex-Container-Start` offset.
  static const int _maxPages = 1000;

  /// Plex's numeric `streamType` for a lyric `Stream` (2 = audio, 3 = subtitle,
  /// 4 = lyrics). The one stream kind [fetchLyrics] looks for on a track's Part.
  static const int _lyricStreamType = 4;

  @override
  Future<PlexServerIdentity> fetchIdentity({
    required String baseUrl,
    required String token,
  }) async {
    final Map<String, dynamic> json =
        await _getJson(PlexEndpoints.identity(baseUrl), token);
    final PlexServerIdentity? identity = PlexServerIdentity.fromJson(json);
    if (identity == null) {
      // A 200 body with no `machineIdentifier`: something answered, but it isn't
      // a recognisable Plex server.
      throw PlexException.notPlex();
    }
    return identity;
  }

  @override
  Future<List<PlexDirectory>> fetchSections({
    required String baseUrl,
    required String token,
  }) async {
    final PlexMediaContainer container =
        await _getContainer(PlexEndpoints.librarySections(baseUrl), token);
    return container.directories;
  }

  @override
  Future<List<PlexMetadata>> fetchSectionItems({
    required String baseUrl,
    required String token,
    required String sectionKey,
    required PlexMetadataType itemType,
  }) async {
    final List<PlexMetadata> items = <PlexMetadata>[];
    // Walk pages until the server reports the whole set is fetched, hands back a
    // short (final) page, or returns nothing. `MediaContainer.totalSize` is the
    // authoritative total; `size` is how many this page actually returned.
    int start = 0;
    for (int page = 0; page < _maxPages; page++) {
      final Uri uri = PlexEndpoints.sectionItems(
        baseUrl,
        sectionKey: sectionKey,
        itemType: itemType,
        start: start,
        size: _pageSize,
      );
      final PlexMediaContainer container = await _getContainer(uri, token);
      items.addAll(container.metadata);

      final int returned = container.size ?? container.metadata.length;
      if (returned <= 0) break;
      start += returned;
      final int? total = container.totalSize;
      if (total != null && start >= total) break;
      if (returned < _pageSize) break;
    }
    return items;
  }

  @override
  Future<PlexMetadata> fetchMetadata({
    required String baseUrl,
    required String token,
    required String ratingKey,
  }) async {
    final PlexMediaContainer container = await _getContainer(
      PlexEndpoints.metadata(baseUrl, ratingKey: ratingKey),
      token,
    );
    if (container.metadata.isEmpty) {
      // A 200 Plex envelope that carried no item — a shape we can't use.
      throw PlexException.unsupportedResponse();
    }
    return container.metadata.first;
  }

  @override
  Future<Lyrics?> fetchLyrics({
    required String baseUrl,
    required String token,
    required String ratingKey,
  }) async {
    // Step 1: the track's full single-item metadata carries its
    // Media → Part → Stream list (streams ride in this response by default);
    // a lyric stream is Plex's streamType=4, whose `key` points at the content.
    final Map<String, dynamic> metadata = await _getJson(
      PlexEndpoints.metadata(baseUrl, ratingKey: ratingKey),
      token,
    );
    final ({String key, String? format})? stream = _findLyricStream(metadata);
    // No lyric stream on the track → no lyrics (a normal outcome, not an error).
    if (stream == null) return null;

    // Step 2: fetch the stream's content and parse it. A 404 means the content
    // has gone missing — treated as "no lyrics" too, never a hard failure.
    final String? body = await _getLyricBody(
      PlexEndpoints.lyricStream(baseUrl, streamKey: stream.key),
      token,
    );
    if (body == null) return null;
    return _parseLyricBody(body, stream.format);
  }

  @override
  Future<void> reportTimeline({
    required String baseUrl,
    required String token,
    required String ratingKey,
    required PlexTimelineState state,
    required Duration time,
    Duration? duration,
  }) async {
    final Uri uri = PlexEndpoints.timeline(
      baseUrl,
      ratingKey: ratingKey,
      state: state,
      timeMs: time.inMilliseconds,
      durationMs: duration?.inMilliseconds,
    );
    // Same transport + status mapping as every API call (token in the header,
    // never the URL), but the body is deliberately not parsed: PMS answers a
    // timeline report with a small (often empty, sometimes XML) body that
    // carries nothing Linthra needs — a 2xx alone means the report landed.
    final http.Response response = await _send(
      () => _client.get(uri, headers: _headers(token)),
    );
    _checkStatus(response);
  }

  /// GETs [uri] with the auth + identity headers, checks the status, and decodes
  /// a JSON `MediaContainer` envelope — throwing [PlexException.notPlex] when the
  /// body isn't a Plex `MediaContainer` (missing envelope, or non-JSON/XML).
  ///
  /// The decode + envelope parse runs on a background isolate for bodies at or
  /// above [_backgroundParseThreshold] (a full library page) and inline for
  /// small ones, so a big scan never blocks the UI on `jsonDecode`. The status
  /// is checked here (a cheap int compare) so error handling never depends on —
  /// or ships off-isolate — the response body.
  Future<PlexMediaContainer> _getContainer(Uri uri, String token) async {
    final http.Response response = await _send(
      () => _client.get(uri, headers: _headers(token)),
    );
    _checkStatus(response);
    final Uint8List bytes = response.bodyBytes;
    final PlexMediaContainer? container =
        bytes.length >= _backgroundParseThreshold
            ? await _backgroundParser(bytes)
            : _parseContainerBytes(bytes);
    if (container == null) {
      throw PlexException.notPlex();
    }
    return container;
  }

  /// Decodes a `MediaContainer` JSON body into a [PlexMediaContainer], or
  /// returns `null` when the body isn't JSON or isn't a Plex `MediaContainer`
  /// envelope (Plex's default XML, an HTML proxy error page, a JSON array, …) —
  /// the caller turns `null` into [PlexException.notPlex], matching the inline
  /// path's old behavior exactly.
  ///
  /// Static and `this`-free so it can run on a background isolate via `compute`.
  /// Decodes the raw bytes as UTF-8 (not `response.body`, which falls back to
  /// latin1 without a charset and would mangle non-ASCII titles/artist names).
  static PlexMediaContainer? _parseContainerBytes(Uint8List bytes) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      // Not JSON at all — e.g. Plex's default XML, or an HTML proxy error page.
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    return PlexMediaContainer.fromJson(decoded);
  }

  /// The default [_backgroundParser]: runs [_parseContainerBytes] on a one-shot
  /// background isolate. A top-level/static tear-off, as `compute` requires.
  static Future<PlexMediaContainer?> _computeParseContainer(Uint8List bytes) =>
      compute(_parseContainerBytes, bytes);

  /// GETs [uri] with the standard headers, maps the status to a [PlexException],
  /// and decodes a JSON object body.
  ///
  /// The [token] rides in the `X-Plex-Token` **header**, so it never reaches
  /// [uri] (which stays token-free and loggable). The identity headers and
  /// `Accept: application/json` are added so the PMS answers with JSON.
  Future<Map<String, dynamic>> _getJson(Uri uri, String token) async {
    final http.Response response = await _send(
      () => _client.get(uri, headers: _headers(token)),
    );
    _checkStatus(response);
    return _decodeObject(response);
  }

  /// GETs a lyric stream's content, returning its body text — or `null` on a 404
  /// (the content is gone: "no lyrics", not a failure). Other non-2xx statuses
  /// throw the usual [PlexException]. Bytes are decoded as UTF-8 so non-ASCII
  /// lyrics aren't mangled.
  Future<String?> _getLyricBody(Uri uri, String token) async {
    final http.Response response = await _send(
      () => _client.get(uri, headers: _headers(token)),
    );
    if (response.statusCode == 404) return null;
    _checkStatus(response);
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// Locates the first lyric stream (Plex `streamType=4`) in a track's metadata
  /// JSON, returning its server-absolute `key` (the path the content is fetched
  /// from) and reported `format` (e.g. `lrc`/`txt`), or `null` when the track
  /// carries none. Walks Metadata → Media → Part → Stream defensively: any
  /// missing or odd level is skipped, never thrown. A relative `key` is refused
  /// (it would splice into the base URL's authority), the same guard the stream
  /// URL builder applies.
  static ({String key, String? format})? _findLyricStream(
    Map<String, dynamic> json,
  ) {
    final Object? container = json['MediaContainer'];
    if (container is! Map<String, dynamic>) return null;
    final Object? metadata = container['Metadata'];
    if (metadata is! List) return null;
    for (final Object? item in metadata) {
      if (item is! Map<String, dynamic>) continue;
      final Object? media = item['Media'];
      if (media is! List) continue;
      for (final Object? rendition in media) {
        if (rendition is! Map<String, dynamic>) continue;
        final Object? parts = rendition['Part'];
        if (parts is! List) continue;
        for (final Object? part in parts) {
          if (part is! Map<String, dynamic>) continue;
          final Object? streams = part['Stream'];
          if (streams is! List) continue;
          for (final Object? stream in streams) {
            if (stream is! Map<String, dynamic>) continue;
            if (_asInt(stream['streamType']) != _lyricStreamType) continue;
            final String? key = _nonEmpty(stream['key']);
            if (key == null || !key.startsWith('/')) continue;
            return (key: key, format: _nonEmpty(stream['format']));
          }
        }
      }
    }
    return null;
  }

  /// Turns a lyric stream body into [Lyrics]. Plex serves either its structured
  /// JSON document (agent / LyricFind lyrics) or the raw `.lrc`/`.txt` file bytes
  /// (a local sidecar). A JSON object body is read structurally; anything else
  /// is the raw text, parsed by the shared [LyricsTextParser] — so a Plex `.lrc`
  /// renders synced and a `.txt` static, exactly like a local sidecar. Returns
  /// `null` when nothing usable remains; total — malformed input never throws.
  static Lyrics? _parseLyricBody(String body, String? format) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null; // Raw .lrc/.txt text (a local sidecar), not JSON.
    }
    if (decoded is Map<String, dynamic>) {
      return _parseStructuredLyrics(decoded);
    }
    return (format?.toLowerCase() == 'txt')
        ? LyricsTextParser.parsePlain(body)
        : LyricsTextParser.parseLrc(body);
  }

  /// Parses Plex's structured lyric JSON: `MediaContainer.Lyrics[].Line[]`, each
  /// line's text the concatenation of its `Span[].text` and its timestamp the
  /// line's (or first span's) `startOffset` in **milliseconds**. Timed lines win
  /// (synced, ordered by time, mirroring the `.lrc` parser); a document with no
  /// offsets degrades to plain lines. `null` when no usable line remains.
  static Lyrics? _parseStructuredLyrics(Map<String, dynamic> json) {
    final Object? container = json['MediaContainer'];
    if (container is! Map<String, dynamic>) return null;
    final Object? documents = container['Lyrics'];
    if (documents is! List) return null;
    final List<LyricLine> timed = <LyricLine>[];
    final List<String> plain = <String>[];
    for (final Object? document in documents) {
      if (document is! Map<String, dynamic>) continue;
      final Object? lines = document['Line'];
      if (lines is! List) continue;
      for (final Object? line in lines) {
        if (line is! Map<String, dynamic>) continue;
        final String text = _structuredLineText(line);
        final int? offsetMs = _structuredLineOffsetMs(line);
        if (offsetMs != null && offsetMs >= 0) {
          timed.add(
            LyricLine(text: text, start: Duration(milliseconds: offsetMs)),
          );
        } else {
          plain.add(text);
        }
      }
    }
    if (timed.isNotEmpty) {
      // Order by time so the model's active-line search (ascending order) holds.
      timed.sort((LyricLine a, LyricLine b) => a.start!.compareTo(b.start!));
      return Lyrics(lines: timed);
    }
    if (plain.isEmpty) return null;
    // Reuse the plain parser's blank-trim + empty→null handling.
    return LyricsTextParser.parsePlain(plain.join('\n'));
  }

  /// The text of one structured lyric line: its `Span[].text` joined in order,
  /// falling back to a line-level `text` when a server reports no spans.
  static String _structuredLineText(Map<String, dynamic> line) {
    final Object? spans = line['Span'];
    if (spans is List) {
      final StringBuffer buffer = StringBuffer();
      for (final Object? span in spans) {
        if (span is Map<String, dynamic> && span['text'] is String) {
          buffer.write(span['text'] as String);
        }
      }
      if (buffer.isNotEmpty) return buffer.toString();
    }
    final Object? text = line['text'];
    return text is String ? text : '';
  }

  /// The millisecond start offset of a structured lyric line: the line's own
  /// `startOffset`, or the first span's when the line carries none; `null` for
  /// an untimed line.
  static int? _structuredLineOffsetMs(Map<String, dynamic> line) {
    final int? lineOffset = _asInt(line['startOffset']);
    if (lineOffset != null) return lineOffset;
    final Object? spans = line['Span'];
    if (spans is List) {
      for (final Object? span in spans) {
        if (span is Map<String, dynamic>) {
          final int? spanOffset = _asInt(span['startOffset']);
          if (spanOffset != null) return spanOffset;
        }
      }
    }
    return null;
  }

  /// Reads a JSON value PMS may emit as a number or a numeric string (e.g.
  /// `streamType`, `startOffset`) as an `int`, or `null` for anything else.
  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// A trimmed, non-empty [String] for a JSON string [value], or `null`.
  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The headers every API call sends: `Accept: application/json` (Plex defaults
  /// to XML), the `X-Plex-Token` **header** (never a query param, so the URL is
  /// safe to log), and the stable [PlexClientIdentity] headers.
  Map<String, String> _headers(String token) => <String, String>{
        'Accept': 'application/json',
        PlexEndpoints.tokenParam: token,
        ..._identity.toHeaders(),
      };

  /// Runs a request with a timeout, turning any transport-level failure (DNS,
  /// refused connection, TLS handshake, timeout) into a single friendly
  /// [PlexException.notReachable].
  ///
  /// Security: the low-level error text could in principle contain a URL, so it
  /// is **never** echoed into the thrown message — only the static, token-free
  /// factory is used.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw PlexException.notReachable();
    } on http.ClientException {
      throw PlexException.notReachable();
    } on Exception {
      // SocketException / HandshakeException and friends: all "can't reach it".
      throw PlexException.notReachable();
    }
  }

  /// Maps an HTTP status to a [PlexException]. 2xx passes; everything else throws
  /// before the body is parsed, so error handling never depends on — or echoes —
  /// response content.
  void _checkStatus(http.Response response) {
    final int code = response.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401 || code == 403) {
      throw PlexException.unauthorized();
    }
    if (code == 404) {
      throw PlexException.notFound();
    }
    if (code >= 500) {
      throw PlexException.serverError(code);
    }
    // Other 4xx (wrong path, proxy 4xx, …) usually mean the address isn't really
    // a Plex API root.
    throw PlexException.notPlex();
  }

  /// Decodes a JSON object body, or throws [PlexException.notPlex] when the body
  /// isn't JSON (Plex's default XML, an HTML error page, …) or isn't an object.
  Map<String, dynamic> _decodeObject(http.Response response) {
    Object? decoded;
    try {
      // Decode the raw bytes as UTF-8 rather than `response.body` (which falls
      // back to latin1 without a charset and would mangle non-ASCII titles and
      // artist names).
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      decoded = jsonDecode(text);
    } on FormatException {
      // Not JSON at all — e.g. Plex's default XML, or an HTML proxy error page.
      throw PlexException.notPlex();
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw PlexException.notPlex();
  }
}
