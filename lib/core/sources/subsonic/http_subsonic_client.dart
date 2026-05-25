import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/subsonic_session.dart';
import 'subsonic_api.dart';
import 'subsonic_auth.dart';
import 'subsonic_client.dart';
import 'subsonic_endpoints.dart';
import 'subsonic_exception.dart';

/// The real [SubsonicClient], backed by `package:http`.
///
/// The only file in the app that constructs Subsonic URLs and parses the
/// `subsonic-response` envelope. Standard HTTPS already works through a reverse
/// proxy/Cloudflare, so there's nothing proxy-specific here beyond turning an
/// HTML/5xx error page into a friendly [SubsonicErrorKind.notSubsonic] /
/// [SubsonicErrorKind.serverError].
///
/// Every failure becomes a [SubsonicException]; the username/salt/token are
/// never written to an exception, so a leaked error string can't expose them.
class HttpSubsonicClient implements SubsonicClient {
  HttpSubsonicClient({http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  /// Subsonic caps `getAlbumList2` page size at 500; a generous page-count cap
  /// stops a runaway loop if a server ever ignores the offset.
  static const int _albumPageSize = 500;
  static const int _maxAlbumPages = 200;

  @override
  Future<SubsonicServerInfo> ping(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
  }) async {
    final Uri uri = SubsonicEndpoints.ping(
      baseUrl,
      username: username,
      credentials: credentials,
    );
    final SubsonicEnvelope envelope = await _get(uri);
    return SubsonicServerInfo(
      apiVersion: envelope.version,
      type: envelope.type,
      serverVersion: envelope.serverVersion,
    );
  }

  @override
  Future<void> verifySession(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.ping(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    await _get(uri);
  }

  @override
  Future<List<SubsonicArtistDto>> getArtists(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.getArtists(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    final SubsonicEnvelope envelope = await _get(uri);

    // Shape: artists.index[].artist[]
    final List<SubsonicArtistDto> artists = <SubsonicArtistDto>[];
    final Object? root = envelope.data['artists'];
    final Object? indexes = root is Map<String, dynamic> ? root['index'] : null;
    if (indexes is List) {
      for (final Object? index in indexes) {
        if (index is! Map<String, dynamic>) continue;
        final Object? list = index['artist'];
        if (list is! List) continue;
        for (final Object? entry in list) {
          if (entry is Map<String, dynamic>) {
            final SubsonicArtistDto? dto = SubsonicArtistDto.fromJson(entry);
            if (dto != null) artists.add(dto);
          }
        }
      }
    }
    return artists;
  }

  @override
  Future<List<SubsonicAlbumDto>> getAlbums(SubsonicSession session) async {
    final SubsonicCredentials credentials = _credentials(session);
    final List<SubsonicAlbumDto> albums = <SubsonicAlbumDto>[];
    // Walk pages until one comes back short of a full page (the last page).
    for (int page = 0; page < _maxAlbumPages; page++) {
      final Uri uri = SubsonicEndpoints.getAlbumList2(
        session.baseUrl,
        username: session.username,
        credentials: credentials,
        size: _albumPageSize,
        offset: page * _albumPageSize,
      );
      final SubsonicEnvelope envelope = await _get(uri);
      final Object? root = envelope.data['albumList2'];
      final Object? list = root is Map<String, dynamic> ? root['album'] : null;
      if (list is! List || list.isEmpty) break;
      for (final Object? entry in list) {
        if (entry is Map<String, dynamic>) {
          final SubsonicAlbumDto? dto = SubsonicAlbumDto.fromJson(entry);
          if (dto != null) albums.add(dto);
        }
      }
      if (list.length < _albumPageSize) break;
    }
    return albums;
  }

  @override
  Future<List<SubsonicSongDto>> getAlbumSongs(
    SubsonicSession session,
    String albumId,
  ) async {
    final Uri uri = SubsonicEndpoints.getAlbum(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      albumId: albumId,
    );
    final SubsonicEnvelope envelope = await _get(uri);
    final Object? root = envelope.data['album'];
    final Object? list = root is Map<String, dynamic> ? root['song'] : null;
    if (list is! List) return const <SubsonicSongDto>[];
    final List<SubsonicSongDto> songs = <SubsonicSongDto>[];
    for (final Object? entry in list) {
      if (entry is Map<String, dynamic>) {
        final SubsonicSongDto? dto = SubsonicSongDto.fromJson(entry);
        if (dto != null) songs.add(dto);
      }
    }
    return songs;
  }

  @override
  Future<SubsonicStreamProbe> probeStream(Uri url) async {
    // A one-byte ranged GET: enough to see the real status and content type the
    // engine will get, without downloading the track. The credential rides in
    // the URL's query — exactly how the engine will fetch — so no extra header
    // is added. The status is returned, not checked, so the caller can tell
    // auth / web-page / non-audio apart; only a transport failure throws.
    final http.Response response = await _send(
      () => _client.get(url, headers: const <String, String>{
        'Accept': '*/*',
        'Range': 'bytes=0-1',
      }),
    );
    return SubsonicStreamProbe(
      statusCode: response.statusCode,
      contentType: response.headers['content-type'],
    );
  }

  SubsonicCredentials _credentials(SubsonicSession session) =>
      SubsonicCredentials(salt: session.salt, token: session.token);

  /// Performs a JSON `GET`, then decodes and validates the `subsonic-response`
  /// envelope — throwing a friendly [SubsonicException] for a transport failure,
  /// a non-2xx status, a non-Subsonic body, or a Subsonic error code.
  Future<SubsonicEnvelope> _get(Uri uri) async {
    final http.Response response = await _send(
      () => _client.get(uri, headers: const <String, String>{
        'Accept': 'application/json',
      }),
    );
    _checkStatus(response);
    final SubsonicEnvelope? envelope =
        SubsonicEnvelope.fromJson(_decodeObject(response));
    if (envelope == null) {
      throw SubsonicException.notSubsonic();
    }
    if (!envelope.isOk) {
      throw _mapErrorCode(envelope.errorCode);
    }
    return envelope;
  }

  /// Runs a request with a timeout, turning any transport-level failure (DNS,
  /// refused connection, TLS handshake, timeout) into a single friendly "not
  /// reachable" error without leaking low-level details (which could include the
  /// credential-bearing URL).
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw SubsonicException.notReachable();
    } on http.ClientException {
      throw SubsonicException.notReachable();
    } on Exception {
      // SocketException / HandshakeException and friends: all "can't reach it".
      throw SubsonicException.notReachable();
    }
  }

  /// Maps an HTTP status to a [SubsonicException]. 2xx passes (the envelope is
  /// inspected next); everything else throws before the body is parsed, so error
  /// handling never depends on — or echoes — response content.
  void _checkStatus(http.Response response) {
    final int code = response.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401 || code == 403) {
      throw SubsonicException.unauthorized();
    }
    if (code >= 500) {
      throw SubsonicException.serverError(code);
    }
    // Other 4xx (wrong path, proxy 4xx, …): the address probably isn't a
    // Subsonic API root.
    throw SubsonicException.notSubsonic();
  }

  /// Maps a Subsonic error [code] (returned inside a 200 response) to a typed,
  /// friendly exception. Credentials errors re-prompt; "not found" is a
  /// stream-unavailable; an incompatible version is unsupported.
  SubsonicException _mapErrorCode(int? code) {
    switch (code) {
      case 40: // wrong username or password
      case 41: // token auth not supported for LDAP
      case 44: // invalid API key
      case 45: // API key not authorized
      case 50: // user not authorized for the operation
        return SubsonicException.unauthorized();
      case 70: // requested data not found
        return SubsonicException.streamUnavailable();
      case 20: // incompatible client version
      case 30: // incompatible server version
        return SubsonicException.unsupportedResponse();
      default:
        return SubsonicException.serverError();
    }
  }

  /// Decodes a JSON object body, or throws [SubsonicErrorKind.notSubsonic] when
  /// the body isn't JSON (e.g. an HTML error page) or isn't an object.
  Map<String, dynamic> _decodeObject(http.Response response) {
    Object? decoded;
    try {
      // Decode the raw bytes as UTF-8 rather than `response.body` (which falls
      // back to latin1 without a charset and would mangle non-ASCII titles).
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      decoded = jsonDecode(text);
    } on FormatException {
      throw SubsonicException.notSubsonic();
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw SubsonicException.notSubsonic();
  }
}
