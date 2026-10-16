import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'subsonic_exception.dart';

/// Serves the streams of a legacy password sign-in to the audio engine from
/// this device, so the engine never holds a URL carrying the password.
///
/// The engines follow redirects on their own, on every request they make:
/// ExoPlayer even from https to http, libmpv anywhere. The stream probe only
/// sees the first request, so a password URL handed to an engine could still
/// be sent on to wherever a server or proxy points a later one (a seek, a
/// retry). The engine is given `http://127.0.0.1:<port>/stream/<token>`
/// instead, and every request it makes is fetched here, from the https address
/// the user entered, with redirects refused.
///
/// What it holds to:
///  - **Loopback only.** Nothing off the device can reach it.
///  - **https only.** [publish] refuses any other upstream.
///  - **A token per stream.** 256 random bits, kept in memory only. The same
///    URL keeps its token, so resolving a song again doesn't pile them up.
///  - **No redirects.** An upstream redirect is never followed; the engine gets
///    an empty `502`, as it does for a page instead of audio, a compressed
///    body, or headers that don't arrive in time.
///  - **Nothing leaks back.** An HTTP error keeps its status but not its body,
///    and only a fixed list of media headers is copied. Nothing here logs.
///  - **Gone on sign-out.** [revokeAll] drops every token and closes the
///    server, cutting transfers in flight. It also starts a new [generation],
///    and a publish for an earlier one is refused, so a resolve still running
///    when its session signed out can't hand the password back.
class SubsonicStreamRelay {
  SubsonicStreamRelay({
    required http.Client client,
    Future<HttpServer> Function()? bind,
    this.headerTimeout = const Duration(seconds: 20),
    this.bodyIdleTimeout = const Duration(seconds: 30),
  })  : _client = client,
        _bind = bind ?? _bindLoopback;

  /// First path segment of every relayed URL.
  static const String pathPrefix = 'stream';

  /// How long the upstream server gets to send its response headers.
  final Duration headerTimeout;

  /// How long the upstream body may go without delivering a byte while the
  /// engine is reading. The countdown pauses while the engine isn't reading
  /// (backpressure), so a paused song doesn't trip it.
  final Duration bodyIdleTimeout;

  final http.Client _client;
  final Future<HttpServer> Function() _bind;

  static final RegExp _rangePattern =
      RegExp(r'^bytes=\d*-\d*(\s*,\s*\d*-\d*)*$');

  /// Response headers copied from upstream. Anything not listed (cookies,
  /// server banners, auth challenges) stays here.
  static const List<String> _relayedHeaders = <String>[
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.etagHeader,
  ];

  HttpServer? _server;
  Future<HttpServer>? _starting;
  bool _closed = false;
  int _generation = 0;

  /// Which sign-in the relay is serving, bumped by every [revokeAll]. A source
  /// takes it when it's built and passes it to [publish].
  int get generation => _generation;

  /// The upstream URL behind each token, and the token for each upstream URL.
  final Map<String, Uri> _upstreamByToken = <String, Uri>{};
  final Map<String, String> _tokenByUpstream = <String, String>{};

  /// A loopback address for [upstream], an https URL carrying the password,
  /// starting the server first if it isn't running.
  ///
  /// Throws [SubsonicException.passwordNeedsHttps] for anything but https, and
  /// [SubsonicException.streamRelayUnavailable] when the relay can't serve or
  /// [generation] is one a [revokeAll] has since ended.
  Future<Uri> publish(Uri upstream, {required int generation}) async {
    if (!upstream.isScheme('https')) {
      throw SubsonicException.passwordNeedsHttps();
    }
    if (generation != _generation) {
      throw SubsonicException.streamRelayUnavailable();
    }
    final HttpServer server = await _ensureStarted();
    // Revoked while it started or while this waited: register nothing.
    if (generation != _generation || !identical(server, _server)) {
      throw SubsonicException.streamRelayUnavailable();
    }
    final String key = upstream.toString();
    final String token = _tokenByUpstream[key] ??= _newToken();
    _upstreamByToken[token] = upstream;
    return Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      pathSegments: <String>[pathPrefix, token],
    );
  }

  /// Forgets every stream and closes the server: the password goes with the
  /// session it belonged to. A later [publish] starts it again.
  Future<void> revokeAll() async {
    _generation++;
    _upstreamByToken.clear();
    _tokenByUpstream.clear();
    final Future<HttpServer>? starting = _starting;
    _starting = null;
    HttpServer? server = _server;
    _server = null;
    if (server == null && starting != null) {
      try {
        server = await starting;
      } catch (_) {
        // A start that failed left nothing to close.
      }
    }
    if (server != null) await server.close(force: true);
  }

  /// [revokeAll], for good: the relay serves nothing after this.
  Future<void> close() async {
    _closed = true;
    await revokeAll();
  }

  Future<HttpServer> _ensureStarted() async {
    final HttpServer? running = _server;
    if (running != null) return running;
    if (_closed) throw SubsonicException.streamRelayUnavailable();
    final Future<HttpServer> starting = _starting ??= _start();
    final HttpServer server;
    try {
      server = await starting;
    } catch (_) {
      if (identical(_starting, starting)) _starting = null;
      throw SubsonicException.streamRelayUnavailable();
    }
    if (identical(_starting, starting)) {
      _server = server;
      _starting = null;
    }
    // A [revokeAll] while it started closed this server: it serves nothing.
    if (!identical(_server, server)) {
      throw SubsonicException.streamRelayUnavailable();
    }
    return server;
  }

  Future<HttpServer> _start() async {
    final HttpServer server = await _bind();
    server.listen(_handle, onError: (Object _) {});
    return server;
  }

  static Future<HttpServer> _bindLoopback() =>
      HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  static String _newToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _handle(HttpRequest request) async {
    // An engine that hangs up mid-stream fails this future; nothing to do.
    unawaited(request.response.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _serve(request);
    } catch (_) {
      try {
        // Throws once headers are out, in which case the engine just sees the
        // transfer end early.
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {
        // The connection is already gone.
      }
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final HttpResponse response = request.response;
    final String method = request.method;
    if (method != 'GET' && method != 'HEAD') {
      response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }
    final List<String> segments = request.uri.pathSegments;
    final Uri? upstream = segments.length == 2 && segments[0] == pathPrefix
        ? _upstreamByToken[segments[1]]
        : null;
    if (upstream == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final String? range =
        request.headers.value(HttpHeaders.rangeHeader)?.trim();
    final http.StreamedResponse? answer = await _fetch(
      method,
      upstream,
      range != null && _rangePattern.hasMatch(range) ? range : null,
    );
    if (answer == null) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    await _relay(method, answer, response);
  }

  /// Asks [upstream] for what the engine asked for, never following a
  /// redirect. Null when there is no usable answer: no headers in time, or a
  /// transport failure (whose message may carry the URL, so it is dropped).
  Future<http.StreamedResponse?> _fetch(
    String method,
    Uri upstream,
    String? range,
  ) async {
    final http.Request request = http.Request(method, upstream)
      ..followRedirects = false
      ..headers[HttpHeaders.acceptEncodingHeader] = 'identity';
    if (range != null) request.headers[HttpHeaders.rangeHeader] = range;
    final Future<http.StreamedResponse> pending = _client.send(request);
    try {
      return await pending.timeout(headerTimeout);
    } on TimeoutException {
      // The request still settles; make sure what it brings goes nowhere.
      unawaited(pending.then<void>(
        (http.StreamedResponse late) => late.stream.listen(null).cancel(),
        onError: (Object _) {},
      ));
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _relay(
    String method,
    http.StreamedResponse answer,
    HttpResponse response,
  ) async {
    final int status = answer.statusCode;
    final bool media =
        status == HttpStatus.ok || status == HttpStatus.partialContent;
    final String encoding =
        (answer.headers[HttpHeaders.contentEncodingHeader] ?? 'identity')
            .trim()
            .toLowerCase();
    final String? contentType = answer.headers[HttpHeaders.contentTypeHeader];

    if ((status >= 300 && status < 400) ||
        (media && (!_looksLikeMedia(contentType) || encoding != 'identity'))) {
      // A redirect, which would take the password elsewhere, or a yes that
      // isn't usable audio: a page (a login screen, a Subsonic error
      // document) or a compressed body the engine wasn't promised.
      await answer.stream.listen(null).cancel();
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    if (!media) {
      // An HTTP error keeps its status, so the engine reports it for what it
      // is, and a 416 its Content-Range, but never the body, which a server
      // or proxy may fill with diagnostics naming the URL and its password.
      await answer.stream.listen(null).cancel();
      response.statusCode = status;
      final String? contentRange =
          answer.headers[HttpHeaders.contentRangeHeader];
      if (status == HttpStatus.requestedRangeNotSatisfiable &&
          contentRange != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = 0;
      await response.close();
      return;
    }

    response.statusCode = status;
    if (contentType != null) {
      response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    for (final String name in _relayedHeaders) {
      final String? value = answer.headers[name];
      if (value != null) response.headers.set(name, value);
    }
    if (status == HttpStatus.partialContent &&
        answer.headers[HttpHeaders.acceptRangesHeader] == null) {
      // It just served a range, so it takes them even if it didn't say so.
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final int? length = answer.contentLength;
    if (length != null && length >= 0) response.contentLength = length;

    if (method == 'HEAD') {
      await answer.stream.listen(null).cancel();
      await response.close();
      return;
    }
    // A stall surfaces as a TimeoutException out of addStream, and an engine
    // that hangs up as a socket error: either way the upstream subscription
    // is cancelled, closing that connection, and the error path in [_handle]
    // ends the transfer.
    await response.addStream(answer.stream.timeout(bodyIdleTimeout));
    await response.close();
  }

  /// Whether a successful answer can be audio. A missing type is allowed; a
  /// document type is not.
  static bool _looksLikeMedia(String? contentType) {
    if (contentType == null) return true;
    final ContentType type;
    try {
      type = ContentType.parse(contentType);
    } on FormatException {
      return false;
    }
    final String primary = type.primaryType.toLowerCase();
    final String sub = type.subType.toLowerCase();
    if (primary == 'text') return false;
    if (primary == 'application' &&
        (sub == 'json' ||
            sub == 'xml' ||
            sub.endsWith('+xml') ||
            sub.endsWith('+json'))) {
      return false;
    }
    return true;
  }
}
