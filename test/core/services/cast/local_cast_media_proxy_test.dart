import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/services/cast/cast_media_access.dart';
import 'package:linthra/core/services/cast/cast_media_relay.dart';
import 'package:linthra/core/services/cast/local_cast_media_proxy.dart';

/// A stand-in music server on loopback. It serves [body] at
/// `/Audio/1/stream?ApiKey=SECRET` with single-range support, answers 401 to a
/// wrong key, and records what the proxy sent it.
class _Upstream {
  _Upstream._(this._server);

  static Future<_Upstream> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _Upstream upstream = _Upstream._(server);
    server.listen(upstream._handle);
    return upstream;
  }

  final HttpServer _server;
  final List<int> body = List<int>.generate(1000, (int i) => i % 256);
  final List<HttpHeaders> requests = <HttpHeaders>[];
  final List<String> methods = <String>[];
  int failWith = 0;

  /// Where `/redirect-away` points.
  String awayLocation = 'http://login.example.test/?return=ApiKey%3DSECRET';

  int get port => _server.port;

  Uri get streamUrl => Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _server.port,
        path: '/Audio/1/stream',
        queryParameters: <String, String>{'ApiKey': 'SECRET'},
      );

  /// A URL on this server with the right key, at [path].
  Uri at(String path) => streamUrl.replace(path: path);

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.headers);
    methods.add(request.method);
    final HttpResponse response = request.response;
    response.headers
      ..set(HttpHeaders.setCookieHeader, 'session=SECRETCOOKIE')
      ..set('x-upstream-banner', 'secret-server');
    switch (request.uri.path) {
      case '/hang':
        // Accepts the request and never answers.
        return;
      case '/stall':
        // Promises 1000 bytes, sends 100, then goes quiet without closing.
        response
          ..headers.contentType = ContentType('audio', 'flac')
          ..contentLength = body.length
          ..add(body.sublist(0, 100));
        await response.flush();
        return;
      case '/redirect-same':
        response
          ..statusCode = HttpStatus.found
          ..headers
              .set(HttpHeaders.locationHeader, '/Audio/1/stream?ApiKey=SECRET');
        await response.close();
        return;
      case '/redirect-away':
        response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, awayLocation);
        await response.close();
        return;
      case '/login':
        response
          ..headers.contentType = ContentType.html
          ..write('<html>sign in, ApiKey=SECRET</html>');
        await response.close();
        return;
      case '/subsonic-error':
        response
          ..headers.contentType = ContentType('text', 'xml')
          ..write('<subsonic-response status="failed"/>');
        await response.close();
        return;
      case '/416-with-body':
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */1000')
          ..write('range error for /Audio/1/stream?ApiKey=SECRET');
        await response.close();
        return;
    }
    if (failWith != 0) {
      response.statusCode = failWith;
      response.write('upstream failure body');
      await response.close();
      return;
    }
    if (request.uri.queryParameters['ApiKey'] != 'SECRET') {
      response
        ..statusCode = HttpStatus.unauthorized
        ..headers.set(HttpHeaders.wwwAuthenticateHeader, 'MediaBrowser')
        ..write('secret-body');
      await response.close();
      return;
    }
    response.headers
      ..contentType = ContentType('audio', 'flac')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.etagHeader, '"abc"');
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    final RegExpMatch? m =
        range == null ? null : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (m != null) {
      final int start = int.parse(m.group(1)!);
      final int end =
          m.group(2)!.isEmpty ? body.length - 1 : int.parse(m.group(2)!);
      if (start >= body.length) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers
              .set(HttpHeaders.contentRangeHeader, 'bytes */${body.length}');
        await response.close();
        return;
      }
      final List<int> slice = body.sublist(start, end + 1);
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/${body.length}')
        ..contentLength = slice.length;
      if (request.method != 'HEAD') response.add(slice);
      await response.close();
      return;
    }
    response.contentLength = body.length;
    if (request.method != 'HEAD') response.add(body);
    await response.close();
  }
}

class _Reply {
  _Reply(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final List<int> body;
}

Future<_Reply> _fetch(
  Uri url, {
  String method = 'GET',
  String? range,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.openUrl(method, url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final HttpClientResponse response = await request.close();
    final List<int> body = <int>[
      for (final List<int> chunk in await response.toList()) ...chunk,
    ];
    return _Reply(response.statusCode, response.headers, body);
  } finally {
    client.close(force: true);
  }
}

CastMedia _media(Uri url) => CastMedia(
      url: url,
      contentType: 'audio/mpeg',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      duration: const Duration(minutes: 3),
      artworkUrl:
          Uri.parse('https://music.example.test/Items/1/Images/Primary'),
      access: CastMediaAccess.undeclared,
    );

void main() {
  late _Upstream upstream;
  late DateTime now;

  LocalCastMediaProxy build({
    Duration idleTimeout = const Duration(minutes: 30),
    Duration tokenLifetime = const Duration(hours: 6),
  }) {
    final LocalCastMediaProxy proxy = LocalCastMediaProxy(
      lanAddress: () async => InternetAddress.loopbackIPv4,
      clock: () => now,
      idleTimeout: idleTimeout,
      tokenLifetime: tokenLifetime,
    );
    addTearDown(proxy.stop);
    return proxy;
  }

  setUp(() async {
    upstream = await _Upstream.start();
    now = DateTime(2026, 9, 27, 12);
  });

  tearDown(() => upstream.close());

  group('tokens', () {
    test('are 256-bit, URL-safe and unpadded', () {
      final String token = LocalCastMediaProxy.newToken();
      expect(token, hasLength(43));
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(base64Url.decode('$token='), hasLength(32));
    });

    test('do not repeat', () {
      final Set<String> tokens = <String>{
        for (int i = 0; i < 2000; i++) LocalCastMediaProxy.newToken(),
      };
      expect(tokens, hasLength(2000));
    });

    test('each published item gets its own token on the phone', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();

      final CastMedia a = proxy.publish(_media(upstream.streamUrl));
      final CastMedia b = proxy.publish(_media(upstream.streamUrl));

      expect(a.url.pathSegments, hasLength(2));
      expect(a.url.pathSegments.first, 'cast');
      expect(a.url.pathSegments.last, isNot(b.url.pathSegments.last));
      expect(a.url.host, InternetAddress.loopbackIPv4.address);
      expect(a.url.port, proxy.baseUrl!.port);
    });

    test('the relayed media carries no trace of the server URL', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();

      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      expect(relayed.url.toString(), isNot(contains('SECRET')));
      expect(relayed.url.toString(), isNot(contains('ApiKey')));
      expect(relayed.url.toString(), isNot(contains('/Audio/')));
      expect(relayed.url.port, isNot(upstream.streamUrl.port));
      expect(relayed.url.hasQuery, isFalse);
      expect(relayed.access, CastMediaAccess.localRelay);
      expect(relayed.access.isLeastPrivilege, isTrue);
      // Metadata survives the swap.
      expect(relayed.title, 'Song');
      expect(relayed.artist, 'Artist');
      expect(relayed.album, 'Album');
      expect(relayed.duration, const Duration(minutes: 3));
      expect(relayed.contentType, 'audio/mpeg');
      expect(relayed.artworkUrl, isNotNull);
    });

    test('the relayed media never prints its token', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();

      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));
      final String token = relayed.url.pathSegments.last;

      expect(relayed.toString(), isNot(contains(token)));
      expect(relayed.toString(), isNot(contains('/cast/')));
      expect('$relayed', contains(relayed.url.host));
    });

    test('an unknown token is a bare 404 and never reaches the server',
        () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(proxy.baseUrl!.replace(
          pathSegments: <String>['cast', LocalCastMediaProxy.newToken()]));

      expect(reply.status, HttpStatus.notFound);
      expect(reply.body, isEmpty);
      expect(upstream.requests, isEmpty);
    });

    test('only /cast/<token> is served', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final String token =
          proxy.publish(_media(upstream.streamUrl)).url.pathSegments.last;
      final Uri base = proxy.baseUrl!;

      for (final List<String> path in <List<String>>[
        <String>[],
        <String>['cast'],
        <String>['other', token],
        <String>['cast', token, 'extra'],
        <String>[token],
      ]) {
        final _Reply reply = await _fetch(base.replace(pathSegments: path));
        expect(reply.status, HttpStatus.notFound, reason: '/${path.join('/')}');
      }
      expect(upstream.requests, isEmpty);
    });

    test('expire after their lifetime, even mid-session', () async {
      final LocalCastMediaProxy proxy =
          build(tokenLifetime: const Duration(hours: 1));
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      now = now.add(const Duration(minutes: 59));
      expect((await _fetch(relayed.url)).status, HttpStatus.ok);

      now = now.add(const Duration(minutes: 1));
      final _Reply expired = await _fetch(relayed.url);
      expect(expired.status, HttpStatus.notFound);
      expect(upstream.requests, hasLength(1));
      // Going back in time does not bring it back: an expired token is gone.
      now = now.subtract(const Duration(hours: 2));
      expect((await _fetch(relayed.url)).status, HttpStatus.notFound);
    });

    test('the previous item keeps working until the receiver asks for the next',
        () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia first = proxy.publish(_media(upstream.streamUrl));
      final CastMedia second = proxy.publish(_media(upstream.streamUrl));

      // A LOAD was sent, nothing more: the receiver is still on the first item,
      // and asking for it again retires nothing.
      expect((await _fetch(first.url)).status, HttpStatus.ok);
      expect((await _fetch(first.url)).status, HttpStatus.ok);

      // Its first request for the second item is the acknowledgement.
      expect((await _fetch(second.url)).status, HttpStatus.ok);

      expect((await _fetch(first.url)).status, HttpStatus.notFound);
      expect((await _fetch(second.url)).status, HttpStatus.ok);
    });

    test('a revoked item goes, and the one still playing stays', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia playing = proxy.publish(_media(upstream.streamUrl));
      expect((await _fetch(playing.url)).status, HttpStatus.ok);
      final CastMedia refused = proxy.publish(_media(upstream.streamUrl));

      proxy.revoke(refused);

      expect((await _fetch(refused.url)).status, HttpStatus.notFound);
      expect((await _fetch(playing.url)).status, HttpStatus.ok);
    });

    test('a token does not survive the session', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      await proxy.stop();
      await proxy.start();
      final Uri sameTokenNewPort =
          proxy.baseUrl!.replace(pathSegments: relayed.url.pathSegments);

      expect((await _fetch(sameTokenNewPort)).status, HttpStatus.notFound);
    });

    test('only GET and HEAD are accepted', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url, method: 'POST');

      expect(reply.status, HttpStatus.methodNotAllowed);
      expect(reply.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
      expect(upstream.requests, isEmpty);
    });
  });

  group('relaying', () {
    test('streams the whole item with its media headers', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url);

      expect(reply.status, HttpStatus.ok);
      expect(reply.body, upstream.body);
      expect(reply.headers.contentType?.mimeType, 'audio/flac');
      expect(reply.headers.contentLength, upstream.body.length);
      expect(reply.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(reply.headers.value(HttpHeaders.etagHeader), '"abc"');
      expect(reply.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    });

    test('fetches the server with the credential, from the phone only',
        () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url);

      // The server was reached with the real key (or it would have said 401)…
      expect(reply.status, HttpStatus.ok);
      // …and none of what the server keeps for its own clients came back.
      expect(reply.headers.value(HttpHeaders.setCookieHeader), isNull);
      expect(reply.headers.value('x-upstream-banner'), isNull);
    });

    test('forwards a Range request and relays 206 Partial Content', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url, range: 'bytes=100-199');

      expect(upstream.requests.single.value(HttpHeaders.rangeHeader),
          'bytes=100-199');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.body, upstream.body.sublist(100, 200));
      expect(reply.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 100-199/1000');
      expect(reply.headers.contentLength, 100);
      expect(reply.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    });

    test('an open-ended range (a seek) returns the rest of the item', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url, range: 'bytes=900-');

      expect(reply.status, HttpStatus.partialContent);
      expect(reply.body, upstream.body.sublist(900));
      expect(reply.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 900-999/1000');
    });

    test('relays 416 for a range past the end', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url, range: 'bytes=5000-');

      expect(reply.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(
          reply.headers.value(HttpHeaders.contentRangeHeader), 'bytes */1000');
    });

    test('a malformed Range is not forwarded', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url, range: 'items=1-2');

      expect(upstream.requests.single.value(HttpHeaders.rangeHeader), isNull);
      expect(reply.status, HttpStatus.ok);
      expect(reply.body, upstream.body);
    });

    test('HEAD answers the headers without a body', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url, method: 'HEAD');

      expect(upstream.methods.single, 'HEAD');
      expect(reply.status, HttpStatus.ok);
      expect(reply.body, isEmpty);
      expect(reply.headers.contentLength, upstream.body.length);
      expect(reply.headers.contentType?.mimeType, 'audio/flac');
    });

    test('an upstream refusal becomes an empty 502', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final Uri wrongKey = upstream.streamUrl
          .replace(queryParameters: <String, String>{'ApiKey': 'WRONG'});
      final CastMedia relayed = proxy.publish(_media(wrongKey));

      final _Reply reply = await _fetch(relayed.url);

      expect(reply.status, HttpStatus.badGateway);
      expect(reply.body, isEmpty);
      expect(reply.headers.value(HttpHeaders.wwwAuthenticateHeader), isNull);
      expect(reply.headers.value(HttpHeaders.setCookieHeader), isNull);
    });

    test('an upstream server error becomes an empty 502', () async {
      upstream.failWith = HttpStatus.internalServerError;
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      final _Reply reply = await _fetch(relayed.url);

      expect(reply.status, HttpStatus.badGateway);
      expect(utf8.decode(reply.body), isNot(contains('upstream')));
    });

    test('a server that never sends headers becomes a 502', () async {
      final LocalCastMediaProxy proxy = LocalCastMediaProxy(
        lanAddress: () async => InternetAddress.loopbackIPv4,
        upstreamHeaderTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(proxy.stop);
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.at('/hang')));

      final _Reply reply =
          await _fetch(relayed.url).timeout(const Duration(seconds: 5));

      expect(reply.status, HttpStatus.badGateway);
      expect(reply.body, isEmpty);
    });

    test('a body that stalls is cut, and the relay can still go idle',
        () async {
      final LocalCastMediaProxy proxy = LocalCastMediaProxy(
        lanAddress: () async => InternetAddress.loopbackIPv4,
        upstreamBodyIdleTimeout: const Duration(milliseconds: 100),
        idleTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(proxy.stop);
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.at('/stall')));

      String outcome;
      try {
        final _Reply reply =
            await _fetch(relayed.url).timeout(const Duration(seconds: 5));
        outcome = reply.body.length < upstream.body.length ? 'cut' : 'full';
      } on TimeoutException {
        outcome = 'hung';
      } on IOException {
        outcome = 'cut';
      }
      expect(outcome, 'cut');

      // Nothing is left in flight, so the idle shutdown can do its job.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(proxy.isRunning, isFalse);
    });

    test('a 416 keeps its status and range but never its body', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed =
          proxy.publish(_media(upstream.at('/416-with-body')));

      final _Reply reply = await _fetch(relayed.url, range: 'bytes=5000-');

      expect(reply.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(
          reply.headers.value(HttpHeaders.contentRangeHeader), 'bytes */1000');
      expect(reply.body, isEmpty);
    });

    test('follows a redirect on the same server', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed =
          proxy.publish(_media(upstream.at('/redirect-same')));

      final _Reply reply = await _fetch(relayed.url);

      expect(reply.status, HttpStatus.ok);
      expect(reply.body, upstream.body);
      expect(upstream.requests, hasLength(2));
    });

    test('refuses a redirect to another host', () async {
      // A real server that would happily serve audio, under another host name.
      final _Upstream other = await _Upstream.start();
      addTearDown(other.close);
      upstream.awayLocation =
          'http://localhost:${other.port}/Audio/1/stream?ApiKey=SECRET';
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed =
          proxy.publish(_media(upstream.at('/redirect-away')));

      final _Reply reply = await _fetch(relayed.url);

      expect(reply.status, HttpStatus.badGateway);
      expect(reply.body, isEmpty);
      expect(reply.headers.value(HttpHeaders.locationHeader), isNull);
      expect(other.requests, isEmpty);
    });

    test('a page instead of audio becomes a 502', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();

      for (final String path in <String>['/login', '/subsonic-error']) {
        final CastMedia relayed = proxy.publish(_media(upstream.at(path)));
        final _Reply reply = await _fetch(relayed.url);
        expect(reply.status, HttpStatus.badGateway, reason: path);
        expect(reply.body, isEmpty, reason: path);
      }
    });

    test('an unreachable server becomes a 502', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final Uri url = upstream.streamUrl;
      await upstream.close();
      final CastMedia relayed = proxy.publish(_media(url));

      final _Reply reply = await _fetch(relayed.url);

      expect(reply.status, HttpStatus.badGateway);
      expect(reply.body, isEmpty);
    });
  });

  group('lifecycle', () {
    test('nothing listens before start, and publish is refused', () {
      final LocalCastMediaProxy proxy = build();

      expect(proxy.isRunning, isFalse);
      expect(proxy.baseUrl, isNull);
      expect(() => proxy.publish(_media(upstream.streamUrl)),
          throwsA(isA<CastMediaRelayException>()));
    });

    test('start is idempotent', () async {
      final LocalCastMediaProxy proxy = build();
      await Future.wait(<Future<void>>[proxy.start(), proxy.start()]);
      final Uri first = proxy.baseUrl!;
      await proxy.start();

      expect(proxy.isRunning, isTrue);
      expect(proxy.baseUrl, first);
    });

    test('binds an OS-chosen port on the LAN address', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();

      expect(proxy.baseUrl!.scheme, 'http');
      expect(proxy.baseUrl!.host, InternetAddress.loopbackIPv4.address);
      expect(proxy.baseUrl!.port, greaterThan(0));
    });

    test('stop closes the socket and refuses publishing', () async {
      final LocalCastMediaProxy proxy = build();
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      await proxy.stop();

      expect(proxy.isRunning, isFalse);
      await expectLater(_fetch(relayed.url), throwsA(isA<SocketException>()));
      expect(() => proxy.publish(_media(upstream.streamUrl)),
          throwsA(isA<CastMediaRelayException>()));
      // A second stop is harmless.
      await proxy.stop();
    });

    test('stops by itself after a quiet spell', () async {
      final LocalCastMediaProxy proxy =
          build(idleTimeout: const Duration(milliseconds: 80));
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(proxy.isRunning, isFalse);
      await expectLater(_fetch(relayed.url), throwsA(isA<SocketException>()));
    });

    test('requests and touch keep it awake', () async {
      final LocalCastMediaProxy proxy =
          build(idleTimeout: const Duration(milliseconds: 150));
      await proxy.start();
      final CastMedia relayed = proxy.publish(_media(upstream.streamUrl));

      for (int i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 75));
        if (i.isEven) {
          proxy.touch();
        } else {
          expect((await _fetch(relayed.url)).status, HttpStatus.ok);
        }
      }

      expect(proxy.isRunning, isTrue);
    });
  });

  group('idle shutdown and untrusted traffic', () {
    test('requests without a live token do not keep the relay awake', () async {
      final LocalCastMediaProxy proxy =
          build(idleTimeout: const Duration(milliseconds: 150));
      await proxy.start();
      proxy.publish(_media(upstream.streamUrl));
      final Uri base = proxy.baseUrl!;

      // A scanner that found the port keeps knocking without a valid token,
      // well past the idle timeout. Once the relay is gone a knock fails to
      // connect, which is the point.
      // Knocks with a raw socket rather than HttpClient: a knock that lands
      // while the relay is closing can be reset mid-request, and every error
      // here has to stay inside the knock.
      Future<void> knock(String requestLine) async {
        try {
          final Socket socket = await Socket.connect(base.host, base.port,
              timeout: const Duration(seconds: 1));
          unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
          socket.write('$requestLine HTTP/1.1\r\nHost: relay\r\n'
              'Connection: close\r\n\r\n');
          await socket.flush();
          await socket.drain<void>().timeout(const Duration(seconds: 1));
          socket.destroy();
        } catch (_) {
          // Nothing listening any more, or the relay went down mid-knock.
        }
      }

      final Stopwatch clock = Stopwatch()..start();
      while (clock.elapsed < const Duration(milliseconds: 450)) {
        await knock('GET /cast/${LocalCastMediaProxy.newToken()}');
        await knock('POST /');
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      // Checked while the knocking is still recent: had it counted as
      // activity, the relay would still be up.
      expect(proxy.isRunning, isFalse);
      expect(upstream.requests, isEmpty);
    });
  });

  group('when it cannot start', () {
    test('no local network is a clean, generic refusal', () async {
      final LocalCastMediaProxy proxy = LocalCastMediaProxy(
        lanAddress: () async => throw const SocketException('no wifi'),
      );

      await expectLater(
        proxy.start(),
        throwsA(isA<CastMediaRelayException>().having(
            (CastMediaRelayException e) => e.message,
            'message',
            CastMediaRelayException.unavailableMessage)),
      );
      expect(proxy.isRunning, isFalse);
    });

    test('a port that cannot be opened is a clean refusal', () async {
      final LocalCastMediaProxy proxy = LocalCastMediaProxy(
        lanAddress: () async => InternetAddress.loopbackIPv4,
        bind: (InternetAddress address) async => throw SocketException(
            'Permission denied',
            address: InternetAddress('192.168.1.20'),
            port: 40000),
      );

      Object? error;
      try {
        await proxy.start();
      } catch (e) {
        error = e;
      }

      expect(error, isA<CastMediaRelayException>());
      expect(error.toString(), isNot(contains('192.168')));
      expect(error.toString(), isNot(contains('40000')));
      expect(proxy.isRunning, isFalse);
    });

    test('an address this device does not own fails to bind for real',
        () async {
      final LocalCastMediaProxy proxy = LocalCastMediaProxy(
        // TEST-NET-3: never assigned to a local interface.
        lanAddress: () async => InternetAddress('203.0.113.7'),
      );

      await expectLater(proxy.start(), throwsA(isA<CastMediaRelayException>()));
      expect(proxy.isRunning, isFalse);
      await proxy.stop();
    });
  });

  group('following redirects', () {
    final Uri original = Uri.parse('http://music.example.test/stream');

    test('allows the same host, and an upgrade to https', () {
      expect(
          LocalCastMediaProxy.isAllowedRedirect(
              original, original, Uri.parse('http://music.example.test/other')),
          isTrue);
      expect(
          LocalCastMediaProxy.isAllowedRedirect(original, original,
              Uri.parse('https://music.example.test:8920/stream')),
          isTrue);
    });

    test('never downgrades relative to the previous hop', () {
      // http, then https, then back to http: the last hop is a downgrade even
      // though it matches the original scheme.
      final Uri upgraded = Uri.parse('https://music.example.test/stream');
      expect(
          LocalCastMediaProxy.isAllowedRedirect(original, upgraded,
              Uri.parse('http://music.example.test/stream')),
          isFalse);
      final Uri secure = Uri.parse('https://music.example.test/stream');
      expect(
          LocalCastMediaProxy.isAllowedRedirect(
              secure, secure, Uri.parse('http://music.example.test/stream')),
          isFalse);
    });

    test('never leaves the original host', () {
      final Uri upgraded = Uri.parse('https://music.example.test/stream');
      expect(
          LocalCastMediaProxy.isAllowedRedirect(
              original, upgraded, Uri.parse('https://login.example.test/')),
          isFalse);
    });
  });

  group('choosing the LAN address', () {
    ({String interface, InternetAddress address}) c(String name, String ip) =>
        (interface: name, address: InternetAddress(ip));

    test('prefers Wi-Fi over mobile data and tunnels', () {
      expect(
        LocalCastMediaProxy
            .pickLanAddress(<({String interface, InternetAddress address})>[
          c('rmnet_data0', '10.20.30.40'),
          c('tun0', '10.8.0.2'),
          c('wlan0', '192.168.1.20'),
        ])?.address,
        '192.168.1.20',
      );
    });

    test('prefers Wi-Fi over Ethernet, and takes Ethernet when alone', () {
      expect(
        LocalCastMediaProxy
            .pickLanAddress(<({String interface, InternetAddress address})>[
          c('eth0', '192.168.0.5'),
          c('wlp3s0', '192.168.1.20'),
        ])?.address,
        '192.168.1.20',
      );
      expect(
        LocalCastMediaProxy
            .pickLanAddress(<({String interface, InternetAddress address})>[
          c('docker0', '172.17.0.1'),
          c('enp0s31f6', '10.0.0.7'),
        ])?.address,
        '10.0.0.7',
      );
    });

    test('never picks a public, CGNAT or tunnel-only address', () {
      expect(
        LocalCastMediaProxy
            .pickLanAddress(<({String interface, InternetAddress address})>[
          c('wlan0', '8.8.8.8'),
          c('wlan1', '100.64.1.2'),
          c('tailscale0', '192.168.50.1'),
          c('wg0', '10.0.0.2'),
          c('ccmni0', '10.1.1.1'),
          c('wlan2', '172.32.0.1'),
        ]),
        isNull,
      );
    });

    test('accepts every private range', () {
      for (final String ip in <String>[
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.1',
        '192.168.8.8'
      ]) {
        expect(
          LocalCastMediaProxy
              .pickLanAddress(<({String interface, InternetAddress address})>[
            c('wlan0', ip),
          ])?.address,
          ip,
        );
      }
    });
  });
}
