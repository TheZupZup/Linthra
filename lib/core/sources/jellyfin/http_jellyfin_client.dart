import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/jellyfin_session.dart';
import 'jellyfin_api.dart';
import 'jellyfin_auth_header.dart';
import 'jellyfin_client.dart';
import 'jellyfin_exception.dart';

/// The real [JellyfinClient], backed by `package:http`.
///
/// This is the only file in the app that constructs Jellyfin URLs, sets the
/// auth header, and parses JSON. Standard HTTPS requests already work through a
/// Cloudflare proxy/tunnel, so there's nothing Cloudflare-specific here beyond
/// turning its error pages (HTML / 5xx) into a friendly
/// [JellyfinErrorKind.notJellyfin] / [JellyfinErrorKind.serverError].
///
/// Every failure becomes a [JellyfinException]; the password and token are
/// never written to an exception, so a leaked error string can't expose them.
class HttpJellyfinClient implements JellyfinClient {
  HttpJellyfinClient({http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  @override
  Future<JellyfinServerInfo> fetchServerInfo(String baseUrl) async {
    final Uri uri = Uri.parse('$baseUrl/System/Info/Public');
    final http.Response response = await _send(
      () => _client.get(uri, headers: const <String, String>{
        'Accept': 'application/json',
      }),
    );
    _checkStatus(response);
    final JellyfinServerInfo? info =
        JellyfinServerInfo.fromJson(_decodeObject(response));
    if (info == null) {
      throw JellyfinException.notJellyfin();
    }
    return info;
  }

  @override
  Future<JellyfinAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/Users/AuthenticateByName');
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': JellyfinAuthHeader.forClient(deviceId),
        },
        // Jellyfin's auth body. The password lives only in this request and is
        // never logged or echoed into an error.
        body: jsonEncode(<String, String>{
          'Username': username,
          'Pw': password,
        }),
      ),
    );
    _checkStatus(response);
    final JellyfinAuthResult? result =
        JellyfinAuthResult.fromJson(_decodeObject(response));
    if (result == null) {
      throw JellyfinException.notJellyfin();
    }
    return result;
  }

  @override
  Future<List<JellyfinItemDto>> fetchItems(
    JellyfinSession session, {
    required JellyfinItemKind kind,
  }) async {
    final Uri uri = _itemsUri(session, kind);
    final http.Response response = await _send(
      () => _client.get(uri, headers: <String, String>{
        'Accept': 'application/json',
        'Authorization':
            JellyfinAuthHeader.forToken(session.deviceId, session.accessToken),
      }),
    );
    _checkStatus(response);

    final Map<String, dynamic> json = _decodeObject(response);
    final Object? rawItems = json['Items'];
    if (rawItems is! List) {
      // A valid but empty library, or a shape we don't recognize — treat as
      // "nothing to list" rather than an error.
      return const <JellyfinItemDto>[];
    }
    final List<JellyfinItemDto> items = <JellyfinItemDto>[];
    for (final Object? entry in rawItems) {
      if (entry is Map<String, dynamic>) {
        final JellyfinItemDto? dto = JellyfinItemDto.fromJson(entry);
        if (dto != null) {
          items.add(dto);
        }
      }
    }
    return items;
  }

  @override
  Future<void> verifySession(JellyfinSession session) async {
    // `/Users/Me` is a tiny authenticated call: a 401 means the token is no
    // longer valid, a transport failure means the server is unreachable. The
    // body is irrelevant, so it is not parsed.
    final Uri uri = Uri.parse('${session.baseUrl}/Users/Me');
    final http.Response response = await _send(
      () => _client.get(uri, headers: <String, String>{
        'Accept': 'application/json',
        'Authorization':
            JellyfinAuthHeader.forToken(session.deviceId, session.accessToken),
      }),
    );
    _checkStatus(response);
  }

  /// Builds the listing URL for [kind]. Artists have their own endpoint in
  /// Jellyfin; tracks and albums share `/Items` filtered by type.
  Uri _itemsUri(JellyfinSession session, JellyfinItemKind kind) {
    switch (kind) {
      case JellyfinItemKind.audio:
        return Uri.parse('${session.baseUrl}/Items').replace(
          queryParameters: <String, String>{
            'UserId': session.userId,
            'Recursive': 'true',
            'IncludeItemTypes': 'Audio',
            'SortBy': 'AlbumArtist,Album,IndexNumber,SortName',
            'SortOrder': 'Ascending',
            'Fields': 'RunTimeTicks',
          },
        );
      case JellyfinItemKind.album:
        return Uri.parse('${session.baseUrl}/Items').replace(
          queryParameters: <String, String>{
            'UserId': session.userId,
            'Recursive': 'true',
            'IncludeItemTypes': 'MusicAlbum',
            'SortBy': 'AlbumArtist,SortName',
            'SortOrder': 'Ascending',
            'Fields': 'ProductionYear,ChildCount',
          },
        );
      case JellyfinItemKind.artist:
        return Uri.parse('${session.baseUrl}/Artists').replace(
          queryParameters: <String, String>{
            'UserId': session.userId,
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
          },
        );
    }
  }

  /// Runs a request with a timeout, turning any transport-level failure (DNS,
  /// refused connection, TLS handshake, timeout) into a single friendly
  /// "not reachable" error without leaking low-level details.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw JellyfinException.notReachable();
    } on http.ClientException {
      throw JellyfinException.notReachable();
    } on Exception {
      // SocketException / HandshakeException and friends: all "can't reach it".
      throw JellyfinException.notReachable();
    }
  }

  /// Maps an HTTP status to a [JellyfinException]. 2xx passes; everything else
  /// throws before the body is parsed, so error handling never depends on
  /// response content (and never echoes it).
  void _checkStatus(http.Response response) {
    final int code = response.statusCode;
    if (code >= 200 && code < 300) {
      return;
    }
    if (code == 401 || code == 403) {
      throw JellyfinException.unauthorized();
    }
    if (code >= 500) {
      throw JellyfinException.serverError(code);
    }
    // Other 4xx (wrong path, Cloudflare 4xx, …) usually mean the address isn't
    // really a Jellyfin API root.
    throw JellyfinException.notJellyfin();
  }

  /// Decodes a JSON object body, or throws [JellyfinErrorKind.notJellyfin] when
  /// the body isn't JSON (e.g. a Cloudflare/HTML error page) or isn't an object.
  Map<String, dynamic> _decodeObject(http.Response response) {
    Object? decoded;
    try {
      // Decode the raw bytes as UTF-8 rather than using `response.body`, which
      // falls back to latin1 when the server omits a charset and would mangle
      // non-ASCII titles and artist names.
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      decoded = jsonDecode(text);
    } on FormatException {
      throw JellyfinException.notJellyfin();
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw JellyfinException.notJellyfin();
  }
}
