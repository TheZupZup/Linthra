import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/audiobookshelf_session.dart';
import 'audiobookshelf_api.dart';
import 'audiobookshelf_client.dart';
import 'audiobookshelf_endpoints.dart';
import 'audiobookshelf_exception.dart';

/// The real [AudiobookshelfClient], backed by `package:http`.
///
/// This is the only file in the app that constructs Audiobookshelf URLs, sets
/// the auth header, and parses JSON for this provider. Every failure becomes
/// an [AudiobookshelfException]; the password and both tokens are never
/// written to an exception, so a leaked error string can't expose them.
class HttpAudiobookshelfClient implements AudiobookshelfClient {
  HttpAudiobookshelfClient({http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  @override
  Future<AudiobookshelfServerStatus> fetchServerStatus(
    String baseUrl,
  ) async {
    final Uri uri = AudiobookshelfEndpoints.status(baseUrl);
    final http.Response response = await _send(
      () => _client.get(uri, headers: const <String, String>{
        'Accept': 'application/json',
      }),
    );
    _checkStatus(response);
    final AudiobookshelfServerStatus? status =
        AudiobookshelfServerStatus.fromJson(_decodeObject(response));
    if (status == null) {
      throw AudiobookshelfException.notAudiobookshelf();
    }
    return status;
  }

  @override
  Future<AudiobookshelfAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final Uri uri = AudiobookshelfEndpoints.login(baseUrl);
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: const <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          // Without this header Audiobookshelf sets the refresh token as an
          // httpOnly cookie instead of returning it in the body — a browser
          // assumption this client (no cookie jar) can't rely on.
          'x-return-tokens': 'true',
        },
        // Audiobookshelf's auth body (passport-local's default field names).
        // The password lives only in this request and is never logged or
        // echoed into an error.
        body: jsonEncode(<String, String>{
          'username': username,
          'password': password,
        }),
      ),
    );
    _checkStatus(response);
    final AudiobookshelfAuthResult? result =
        AudiobookshelfAuthResult.fromJson(_decodeObject(response));
    if (result == null) {
      throw AudiobookshelfException.notAudiobookshelf();
    }
    return result;
  }

  @override
  Future<AudiobookshelfAuthResult> refreshTokens({
    required String baseUrl,
    required String refreshToken,
  }) async {
    final Uri uri = AudiobookshelfEndpoints.refresh(baseUrl);
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: <String, String>{
          'Accept': 'application/json',
          // The header (rather than the cookie a browser would send) is also
          // what makes the server return the new refresh token in the body.
          // Never in the URL, where a proxy log would keep it.
          'x-refresh-token': refreshToken,
        },
      ),
    );
    _checkStatus(response);
    // The answer has the login response's shape.
    final AudiobookshelfAuthResult? result =
        AudiobookshelfAuthResult.fromJson(_decodeObject(response));
    if (result == null) {
      throw AudiobookshelfException.unsupportedResponse();
    }
    return result;
  }

  @override
  Future<List<AudiobookshelfLibraryDto>> fetchLibraries(
    AudiobookshelfSession session,
  ) async {
    final Uri uri = AudiobookshelfEndpoints.libraries(session.baseUrl);
    final http.Response response = await _send(
      () => _client.get(uri, headers: <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer ${session.accessToken}',
      }),
    );
    _checkStatus(response);
    final Map<String, dynamic> json = _decodeObject(response);
    final Object? rawLibraries = json['libraries'];
    if (rawLibraries is! List) {
      // A valid but empty account, or a shape we don't recognize — treat as
      // no libraries rather than an error.
      return const <AudiobookshelfLibraryDto>[];
    }
    final List<AudiobookshelfLibraryDto> libraries =
        <AudiobookshelfLibraryDto>[];
    for (final Object? entry in rawLibraries) {
      if (entry is! Map<String, dynamic>) continue;
      final AudiobookshelfLibraryDto? library =
          AudiobookshelfLibraryDto.fromJson(entry);
      // A single malformed entry is skipped, never thrown — one bad library
      // record can't fail the whole listing.
      if (library != null) libraries.add(library);
    }
    return libraries;
  }

  @override
  Future<AudiobookshelfLibraryItemsPage> fetchLibraryItems(
    AudiobookshelfSession session, {
    required String libraryId,
    required int limit,
    required int page,
  }) async {
    final Uri uri = AudiobookshelfEndpoints.libraryItems(
      session.baseUrl,
      libraryId,
      limit: limit,
      page: page,
    );
    final http.Response response = await _send(
      () => _client.get(uri, headers: <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer ${session.accessToken}',
      }),
    );
    _checkStatus(response);
    return AudiobookshelfLibraryItemsPage.fromJson(
      _decodeObject(response),
      requestedPage: page,
    );
  }

  Future<http.Response> _send(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw AudiobookshelfException.notReachable();
    } on http.ClientException {
      throw AudiobookshelfException.notReachable();
    } on Exception {
      // SocketException / HandshakeException and friends: all "can't reach
      // it".
      throw AudiobookshelfException.notReachable();
    }
  }

  /// Maps an HTTP status to an [AudiobookshelfException]. 2xx passes;
  /// everything else throws before the body is parsed, so error handling
  /// never depends on response content (and never echoes it).
  void _checkStatus(http.Response response) {
    final int code = response.statusCode;
    if (code >= 200 && code < 300) {
      return;
    }
    if (code == 401 || code == 403) {
      throw AudiobookshelfException.unauthorized(statusCode: code);
    }
    if (code >= 500) {
      throw AudiobookshelfException.serverError(code);
    }
    if (code == 408 || code == 429) {
      // A request timeout or a rate-limit (often a Cloudflare/reverse-proxy
      // 429) is transient, not a wrong address.
      throw AudiobookshelfException.serverError(code);
    }
    // Other 4xx (wrong path, Cloudflare 4xx, …) usually mean the address
    // isn't really an Audiobookshelf API root.
    throw AudiobookshelfException.notAudiobookshelf();
  }

  /// Decodes a JSON object body, or throws
  /// [AudiobookshelfErrorKind.notAudiobookshelf] when the body isn't JSON
  /// (e.g. a Cloudflare/HTML error page) or isn't an object.
  Map<String, dynamic> _decodeObject(http.Response response) {
    Object? decoded;
    try {
      // Decode the raw bytes as UTF-8 rather than using `response.body`,
      // which falls back to latin1 when the server omits a charset and would
      // mangle non-ASCII titles and author names.
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      decoded = jsonDecode(text);
    } on FormatException {
      throw AudiobookshelfException.notAudiobookshelf();
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw AudiobookshelfException.notAudiobookshelf();
  }
}
