import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'plex_client.dart';
import 'plex_exception.dart';
import 'plex_tv_api.dart';
import 'plex_tv_client.dart';
import 'plex_tv_endpoints.dart';

/// The real [PlexTvClient], backed by `package:http`.
///
/// The only file in the app that talks to plex.tv over HTTP (the sibling of
/// `HttpPlexClient`, which owns the user's own server): it sets
/// `Accept: application/json`, the [PlexClientIdentity] headers — plex.tv
/// binds a PIN to the `X-Plex-Client-Identifier` that minted it, so the same
/// identity must sign every call — and, only where a call needs one, the
/// account token as the `X-Plex-Token` **header**. Every URL it requests is
/// token-free and safe to log.
///
/// Every failure becomes a [PlexException] built from a static, plex.tv-worded
/// factory; no token is ever written into an exception, a log, or any other
/// output. See docs/plex.md → Token safety rules.
class HttpPlexTvClient implements PlexTvClient {
  HttpPlexTvClient({
    required PlexClientIdentity identity,
    http.Client? httpClient,
  })  : _identity = identity,
        _client = httpClient ?? http.Client();

  final PlexClientIdentity _identity;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  @override
  Future<PlexPin> createPin() async {
    final http.Response response = await _send(
      () => _client.post(PlexTvEndpoints.pins(), headers: _headers()),
    );
    _checkStatus(response);
    final PlexPin? pin = PlexPin.fromJson(_decodeObject(response));
    if (pin == null) {
      // A 2xx body without an id/code: nothing Linthra could poll.
      throw PlexException.plexTvUnexpected();
    }
    return pin;
  }

  @override
  Future<String?> checkPin(int pinId) async {
    final http.Response response = await _send(
      () => _client.get(PlexTvEndpoints.pin(pinId), headers: _headers()),
    );
    if (response.statusCode == 404) {
      // plex.tv discarded the PIN before it was approved — definitive, so the
      // poll loop stops instead of spinning on a dead id.
      throw PlexException.signInExpired();
    }
    _checkStatus(response);
    final Object? token = _decodeObject(response)['authToken'];
    if (token is String && token.isNotEmpty) {
      return token;
    }
    return null;
  }

  @override
  Future<List<PlexResource>> fetchResources({required String token}) async {
    final http.Response response = await _send(
      () => _client.get(
        PlexTvEndpoints.resources(),
        headers: _headers(token: token),
      ),
    );
    _checkStatus(response);
    final Object? decoded = _decode(response);
    if (decoded is! List) {
      // /api/v2/resources answers a bare JSON array; anything else isn't a
      // response Linthra can use.
      throw PlexException.plexTvUnexpected();
    }
    return <PlexResource>[
      for (final Object? entry in decoded)
        if (entry is Map<String, dynamic>)
          if (PlexResource.fromJson(entry) case final PlexResource resource)
            resource,
    ];
  }

  @override
  Future<List<PlexHomeUser>> fetchHomeUsers({required String token}) async {
    final http.Response response = await _send(
      () => _client.get(
        PlexTvEndpoints.homeUsers(),
        headers: _headers(token: token),
      ),
    );
    _checkStatus(response);
    final Object? decoded = _decode(response);
    // api/v2 answers an object with a `users` array; tolerate a bare array too
    // so an older/alternate envelope still parses.
    final Object? rawUsers =
        decoded is Map<String, dynamic> ? decoded['users'] : decoded;
    if (rawUsers is! List) {
      throw PlexException.plexTvUnexpected();
    }
    return <PlexHomeUser>[
      for (final Object? entry in rawUsers)
        if (entry is Map<String, dynamic>)
          if (PlexHomeUser.fromJson(entry) case final PlexHomeUser user) user,
    ];
  }

  @override
  Future<String> switchHomeUser({
    required String uuid,
    required String token,
    String? pin,
  }) async {
    final http.Response response = await _send(
      () => _client.post(
        PlexTvEndpoints.switchHomeUser(uuid: uuid, pin: pin),
        headers: _headers(token: token),
      ),
    );
    _checkStatus(response);
    final Object? authToken = _decodeObject(response)['authToken'];
    if (authToken is String && authToken.isNotEmpty) {
      return authToken;
    }
    // A 2xx switch with no token is unusable — there's nothing to connect with.
    throw PlexException.plexTvUnexpected();
  }

  /// The headers every plex.tv call sends: `Accept: application/json`, the
  /// stable client-identity headers, and — only when a call needs one — the
  /// account [token] as the `X-Plex-Token` **header** (never a query param,
  /// so the URLs stay token-free and loggable).
  Map<String, String> _headers({String? token}) => <String, String>{
        'Accept': 'application/json',
        if (token != null) 'X-Plex-Token': token,
        ..._identity.toHeaders(),
      };

  /// Runs a request with a timeout, turning any transport-level failure into
  /// the single friendly [PlexException.plexTvUnreachable].
  ///
  /// Security: the low-level error text is **never** echoed into the thrown
  /// message — only the static, token-free factory is used.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw PlexException.plexTvUnreachable();
    } on http.ClientException {
      throw PlexException.plexTvUnreachable();
    } on Exception {
      // SocketException / HandshakeException and friends: all "can't reach".
      throw PlexException.plexTvUnreachable();
    }
  }

  /// Maps an HTTP status to a [PlexException]. 2xx passes; everything else
  /// throws before the body is parsed, so error handling never depends on —
  /// or echoes — response content. (A PIN-poll 404 is handled by the caller,
  /// which knows it means "expired", before this runs.)
  void _checkStatus(http.Response response) {
    final int code = response.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401 || code == 403) {
      throw PlexException.signInRejected();
    }
    if (code >= 500) {
      throw PlexException.plexTvError(code);
    }
    throw PlexException.plexTvUnexpected(code);
  }

  /// Decodes a JSON object body, or throws [PlexException.plexTvUnexpected]
  /// when the body isn't a JSON object.
  Map<String, dynamic> _decodeObject(http.Response response) {
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw PlexException.plexTvUnexpected();
  }

  /// Decodes a JSON body of any shape (the resources endpoint answers a bare
  /// array), or throws [PlexException.plexTvUnexpected] for non-JSON.
  Object? _decode(http.Response response) {
    try {
      // Decode the raw bytes as UTF-8 rather than `response.body` (which
      // falls back to latin1 without a charset and would mangle non-ASCII
      // server names).
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      return jsonDecode(text);
    } on FormatException {
      // Not JSON at all — e.g. plex.tv's default XML or an HTML error page.
      throw PlexException.plexTvUnexpected();
    }
  }
}
