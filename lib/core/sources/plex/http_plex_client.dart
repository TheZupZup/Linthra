import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
