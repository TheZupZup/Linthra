import 'dart:convert';
import 'dart:io';

import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/plex/plex_endpoints.dart';

/// Loopback HTTP servers that answer the handful of endpoints one provider's
/// *playback* path actually calls, so a test can drive the real resolver, the
/// real HTTP client and the real URL builders without a home server, a
/// credential, or the public internet.
///
/// Why a socket rather than a `MockClient`: the thing worth proving about
/// remote playback on Linux is that a freshly minted, credential-bearing URL is
/// accepted by something that checks the credential the way a server does, and
/// that the bytes reach the engine. A response function substituted into the
/// HTTP client can only replay what the test already decided; a server that
/// verifies `ApiKey` / `t=` / `X-Plex-Token` and answers 401 when it doesn't
/// match makes the assertion real. Everything stays deterministic: the port is
/// ephemeral, the address is `127.0.0.1`, the payload is fixed, and every
/// server is torn down with the test.
///
/// Credentials here are synthetic constants, never CI secrets, and the servers
/// only ever see the ones this file hands them.
abstract class FakeProviderServer {
  HttpServer? _server;

  /// Every request the server received, in order. This is the *server's own*
  /// side of the boundary, so it deliberately keeps the credential it was sent
  /// — that is what makes "the engine really fetched with a fresh token"
  /// assertable. Nothing here is logged by the app.
  final List<FakeServerRequest> requests = <FakeServerRequest>[];

  /// Whether the session is still accepted. Flip to false to play out a
  /// provider/session expiry mid-test: authenticated endpoints answer the way
  /// each provider reports a rejected credential.
  bool sessionValid = true;

  /// How many further *stream* requests fail with [streamFailureStatus] before
  /// the endpoint starts working again. Drives candidate fallback and the
  /// bounded re-resolution path.
  int failingStreamRequests = 0;

  /// The status a failing stream request answers with.
  int streamFailureStatus = 503;

  /// When true, every request has its socket destroyed instead of answered —
  /// what a sleeping NAS looks like to an HTTP client: a transport failure,
  /// never a status.
  bool refuseConnections = false;

  /// The two bytes a ranged probe reads, and the whole "file" the engine
  /// fetches. Small, fixed, and not real audio: nothing decodes it here.
  static const List<int> audioBytes = <int>[0x4C, 0x49, 0x4E, 0x54, 0x48, 0x52];

  /// The content type the stream endpoints report, so the probe's
  /// `isAudio` check passes for a healthy stream.
  String get audioContentType;

  /// Digits that a status-reading error classifier would misread if they turned
  /// up in a port number. See [start].
  static const List<String> _statusLikeDigits = <String>['401', '403'];

  static bool _portIsSafe(int port) => !_statusLikeDigits.any('$port'.contains);

  /// Binds an ephemeral loopback port, skipping the few that would make an
  /// engine error quoting the URL read as an HTTP auth failure.
  ///
  /// This looks fussy and is not. A mid-stream failure arrives as the engine's
  /// own error text, which quotes the URL it was fetching, and
  /// `classifyEngineError` reads that text for `401` / `403` to tell an expired
  /// session from a dropped connection. Land on port 40123 and a transient drop
  /// is classified as an expired session, so the bounded retry never runs — a
  /// flake with nothing to do with the code under test. One in a few hundred
  /// binds, which is exactly often enough to be miserable, so it is ruled out
  /// here instead.
  Future<void> start() async {
    for (int attempt = 0; attempt < 64; attempt++) {
      final HttpServer candidate =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (_portIsSafe(candidate.port)) {
        _server = candidate;
        candidate.listen(_dispatch);
        return;
      }
      await candidate.close(force: true);
    }
    throw StateError(
      'could not bind a loopback port free of HTTP-status digits',
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  int get port => _server!.port;

  /// The clean base URL a session points at, in the shape
  /// `*ServerUrl.normalize` produces (no trailing slash).
  String get baseUrl => 'http://127.0.0.1:$port';

  /// Requests whose path is this provider's audio stream, from either side of
  /// the boundary.
  List<FakeServerRequest> get streamRequests =>
      requests.where((FakeServerRequest r) => isStreamPath(r.path)).toList();

  /// The resolver's one-byte ranged probe of a freshly minted stream URL
  /// (`Range: bytes=0-1`, see `Http*Client.probeStream`). Counting these counts
  /// resolutions. Plex has no probe step, so this is always empty there and its
  /// resolutions are counted by [FakePlexServer.metadataRequests] instead.
  List<FakeServerRequest> get streamProbes => streamRequests
      .where((FakeServerRequest r) => r.headers.containsKey('range'))
      .toList();

  /// The engine's own fetch of the resolved URL: a plain GET, no range. One per
  /// track actually handed to playback.
  List<FakeServerRequest> get streamFetches => streamRequests
      .where((FakeServerRequest r) => !r.headers.containsKey('range'))
      .toList();

  /// Whether [path] is this provider's audio-stream endpoint.
  bool isStreamPath(String path);

  /// Answers one request. Implementations only see requests that were not
  /// refused outright.
  Future<void> handle(HttpRequest request);

  Future<void> _dispatch(HttpRequest request) async {
    requests.add(FakeServerRequest.from(request));
    if (refuseConnections) {
      final Socket socket = await request.response.detachSocket();
      socket.destroy();
      return;
    }
    await handle(request);
  }

  /// Writes the audio response: 206 + `content-range` for the resolver's
  /// one-byte probe, 200 for a whole-file fetch, mirroring what a real server
  /// does with the `Range` header each caller sends.
  Future<void> writeAudio(HttpRequest request) async {
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    final HttpResponse response = request.response
      ..headers.contentType = ContentType.parse(audioContentType);
    if (range == null) {
      response.statusCode = HttpStatus.ok;
      response.add(audioBytes);
    } else {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 0-1/${audioBytes.length}',
      );
      response.add(audioBytes.sublist(0, 2));
    }
    await response.close();
  }

  /// Claims one of the queued stream failures, if any are left.
  bool claimStreamFailure() {
    if (failingStreamRequests <= 0) return false;
    failingStreamRequests--;
    return true;
  }

  Future<void> writeJson(HttpRequest request, Map<String, Object?> body,
      {int status = HttpStatus.ok}) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> writeStatus(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }
}

/// One request a fake server answered, reduced to the parts a test asserts on.
class FakeServerRequest {
  FakeServerRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.headers,
  });

  factory FakeServerRequest.from(HttpRequest request) {
    final Map<String, String> headers = <String, String>{};
    request.headers.forEach((String name, List<String> values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    return FakeServerRequest(
      method: request.method,
      path: request.uri.path,
      query: Map<String, String>.unmodifiable(request.uri.queryParameters),
      headers: Map<String, String>.unmodifiable(headers),
    );
  }

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
}

// --- Jellyfin ---------------------------------------------------------------

/// The synthetic Jellyfin access token these tests sign with. Never a real one.
const String syntheticJellyfinToken = 'synthetic-jellyfin-access-0001';

/// A Jellyfin server that answers the two calls playback makes: the session
/// check (`GET /Users/Me`, token in the `Authorization` header) and the
/// direct-play stream (`GET /Audio/<id>/stream`, token in the `ApiKey` query,
/// because that is what the audio engine fetches with).
class FakeJellyfinServer extends FakeProviderServer {
  FakeJellyfinServer({
    this.accessToken = syntheticJellyfinToken,
    this.knownItemIds = const <String>{},
  });

  final String accessToken;

  /// Item ids that exist. An id outside this set answers 404, which is how a
  /// vanished item reaches the resolver. Empty means "every id exists".
  final Set<String> knownItemIds;

  @override
  String get audioContentType => 'audio/flac';

  @override
  bool isStreamPath(String path) =>
      path.startsWith('/Audio/') && path.endsWith('/stream');

  @override
  Future<void> handle(HttpRequest request) async {
    final String path = request.uri.path;
    if (path == '/Users/Me') {
      if (!sessionValid || !_headerCarriesToken(request)) {
        return writeStatus(request, HttpStatus.unauthorized);
      }
      return writeJson(request, <String, Object?>{'Id': 'user-1'});
    }
    if (isStreamPath(path)) {
      if (!sessionValid ||
          request.uri.queryParameters['ApiKey'] != accessToken) {
        return writeStatus(request, HttpStatus.unauthorized);
      }
      if (claimStreamFailure()) {
        return writeStatus(request, streamFailureStatus);
      }
      final String itemId =
          path.substring('/Audio/'.length, path.length - '/stream'.length);
      if (knownItemIds.isNotEmpty && !knownItemIds.contains(itemId)) {
        return writeStatus(request, HttpStatus.notFound);
      }
      return writeAudio(request);
    }
    return writeStatus(request, HttpStatus.notFound);
  }

  bool _headerCarriesToken(HttpRequest request) {
    final String? header =
        request.headers.value(HttpHeaders.authorizationHeader);
    return header != null && header.contains('Token="$accessToken"');
  }

  /// A session pointed at this server, signed with the synthetic token.
  JellyfinSession get session => JellyfinSession(
        baseUrl: baseUrl,
        userId: 'user-1',
        accessToken: accessToken,
        deviceId: 'device-1',
        userName: 'listener',
        serverName: 'Fake Jellyfin',
      );
}

// --- Subsonic / Navidrome ---------------------------------------------------

/// The synthetic Subsonic salt+token pair these tests sign with. `token` is
/// `md5(password + salt)` in production; here it is a fixed synthetic string,
/// because nothing recomputes it.
const String syntheticSubsonicSalt = 'synthetic-salt-0002';
const String syntheticSubsonicToken = 'synthetic-subsonic-token-0002';

/// A Subsonic/Navidrome server that answers the two calls playback makes:
/// `GET /rest/ping.view` and `GET /rest/stream.view`, both carrying the
/// salt+token in the query, as Subsonic auth always does.
class FakeSubsonicServer extends FakeProviderServer {
  FakeSubsonicServer({
    this.username = 'listener',
    this.salt = syntheticSubsonicSalt,
    this.token = syntheticSubsonicToken,
  });

  final String username;
  final String salt;
  final String token;

  @override
  String get audioContentType => 'audio/mpeg';

  @override
  bool isStreamPath(String path) => path == '/rest/stream.view';

  @override
  Future<void> handle(HttpRequest request) async {
    final String path = request.uri.path;
    final Map<String, String> query = request.uri.queryParameters;
    final bool authorized = sessionValid &&
        query['u'] == username &&
        query['t'] == token &&
        query['s'] == salt;

    if (path == '/rest/ping.view') {
      // Subsonic reports a rejected credential inside a 200 envelope
      // (error code 40), not as an HTTP status.
      if (!authorized) return writeJson(request, _failed(40));
      return writeJson(request, _ok());
    }
    if (isStreamPath(path)) {
      if (!authorized) return writeStatus(request, HttpStatus.unauthorized);
      if (claimStreamFailure()) {
        return writeStatus(request, streamFailureStatus);
      }
      return writeAudio(request);
    }
    return writeStatus(request, HttpStatus.notFound);
  }

  Map<String, Object?> _ok() => <String, Object?>{
        'subsonic-response': <String, Object?>{
          'status': 'ok',
          'version': '1.16.1',
          'type': 'navidrome',
          'serverVersion': '0.53.0',
        },
      };

  Map<String, Object?> _failed(int code) => <String, Object?>{
        'subsonic-response': <String, Object?>{
          'status': 'failed',
          'version': '1.16.1',
          'error': <String, Object?>{'code': code, 'message': 'rejected'},
        },
      };

  /// A session pointed at this server, signed with the synthetic credential.
  SubsonicSession get session => SubsonicSession(
        baseUrl: baseUrl,
        username: username,
        salt: salt,
        token: token,
        serverType: 'navidrome',
      );
}

// --- Plex -------------------------------------------------------------------

/// The synthetic, server-scoped Plex token these tests sign with.
const String syntheticPlexToken = 'synthetic-plex-token-0003';

/// A Plex Media Server that answers the three calls playback makes: the session
/// check (`GET /identity`), the two-step Part lookup
/// (`GET /library/metadata/<ratingKey>`) — both with the token in the
/// `X-Plex-Token` *header* — and the Part fetch itself, where the token rides
/// in the *query* because the engine cannot set headers.
class FakePlexServer extends FakeProviderServer {
  FakePlexServer({
    this.token = syntheticPlexToken,
    this.machineIdentifier = 'fake-machine-0003',
    this.knownRatingKeys = const <String>{},
    this.itemsWithoutPart = const <String>{},
  });

  final String token;
  final String machineIdentifier;

  /// Rating keys that exist; empty means "every key exists".
  final Set<String> knownRatingKeys;

  /// Rating keys whose item carries no playable Part — the "nothing to
  /// direct-play" outcome, distinct from a vanished item.
  final Set<String> itemsWithoutPart;

  @override
  String get audioContentType => 'audio/flac';

  @override
  bool isStreamPath(String path) => path.startsWith('/library/parts/');

  /// The server-absolute Part path for [ratingKey], as PMS reports it.
  static String partKeyFor(String ratingKey) =>
      '/library/parts/$ratingKey/file.flac';

  /// The item lookups playback made. Plex resolves in two steps and does not
  /// probe the stream, so this is what counts a resolution here.
  List<FakeServerRequest> get metadataRequests => requests
      .where((FakeServerRequest r) => r.path.startsWith('/library/metadata/'))
      .toList();

  @override
  Future<void> handle(HttpRequest request) async {
    final String path = request.uri.path;
    if (path == '/identity') {
      if (!_headerCarriesToken(request)) {
        return writeStatus(request, HttpStatus.unauthorized);
      }
      return writeJson(request, <String, Object?>{
        'MediaContainer': <String, Object?>{
          'machineIdentifier': machineIdentifier,
          'version': '1.40.0.0',
        },
      });
    }
    if (path.startsWith('/library/metadata/')) {
      if (!_headerCarriesToken(request)) {
        return writeStatus(request, HttpStatus.unauthorized);
      }
      final String ratingKey = path.substring('/library/metadata/'.length);
      if (knownRatingKeys.isNotEmpty && !knownRatingKeys.contains(ratingKey)) {
        return writeStatus(request, HttpStatus.notFound);
      }
      return writeJson(request, _metadata(ratingKey));
    }
    if (isStreamPath(path)) {
      if (!sessionValid ||
          request.uri.queryParameters[PlexEndpoints.tokenParam] != token) {
        return writeStatus(request, HttpStatus.unauthorized);
      }
      if (claimStreamFailure()) {
        return writeStatus(request, streamFailureStatus);
      }
      return writeAudio(request);
    }
    return writeStatus(request, HttpStatus.notFound);
  }

  Map<String, Object?> _metadata(String ratingKey) => <String, Object?>{
        'MediaContainer': <String, Object?>{
          'size': 1,
          'Metadata': <Object?>[
            <String, Object?>{
              'ratingKey': ratingKey,
              'title': 'Fake Plex Track',
              'Media': itemsWithoutPart.contains(ratingKey)
                  ? const <Object?>[]
                  : <Object?>[
                      <String, Object?>{
                        'Part': <Object?>[
                          <String, Object?>{'key': partKeyFor(ratingKey)},
                        ],
                      },
                    ],
            },
          ],
        },
      };

  bool _headerCarriesToken(HttpRequest request) =>
      sessionValid && request.headers.value(PlexEndpoints.tokenParam) == token;

  /// A session pointed at this server, signed with the synthetic token.
  PlexSession get session => PlexSession(
        baseUrl: baseUrl,
        token: token,
        machineIdentifier: machineIdentifier,
        serverName: 'Fake Plex',
        clientIdentifier: 'install-uuid-1',
      );
}
