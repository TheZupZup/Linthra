import 'dart:async';
import 'dart:convert';

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
/// Every failure becomes a [PlexException]; the token is never written into an
/// exception, a log, or any other output, so a leaked error string can't expose
/// it. Transport errors are classified from the low-level failure but only the
/// static, secret-free factory messages are ever thrown.
class HttpPlexClient implements PlexClient {
  HttpPlexClient({
    required PlexClientIdentity identity,
    http.Client? httpClient,
    int pageSize = _defaultPageSize,
  })  : assert(pageSize > 0, 'pageSize must be positive'),
        _identity = identity,
        _pageSize = pageSize,
        _client = httpClient ?? http.Client();

  final PlexClientIdentity _identity;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  /// A page is requested this large; large libraries are walked page by page.
  /// Overridable via the constructor (mainly so tests can exercise the paged
  /// walk without 200-item fixtures).
  static const int _defaultPageSize = 200;
  final int _pageSize;

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

  /// GETs [uri] with the auth + identity headers, checks the status, and decodes
  /// a JSON `MediaContainer` envelope — throwing [PlexException.notPlex] when the
  /// body isn't a Plex `MediaContainer` (missing envelope, or non-JSON/XML).
  Future<PlexMediaContainer> _getContainer(Uri uri, String token) async {
    final PlexMediaContainer? container =
        PlexMediaContainer.fromJson(await _getJson(uri, token));
    if (container == null) {
      throw PlexException.notPlex();
    }
    return container;
  }

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
