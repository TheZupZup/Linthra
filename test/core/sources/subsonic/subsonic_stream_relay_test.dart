import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/services/cast/local_cast_media_proxy.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_relay.dart';

/// A stream URL carrying a legacy password, the only kind the relay serves.
final Uri _upstream = Uri.parse(
  'https://cloud.example.com/rest/stream.view?u=alice&'
  'p=${SubsonicAuth.encodePassword('app-password')}&id=s1',
);

/// What the engine gets back from the relay, read in full.
class _EngineAnswer {
  _EngineAnswer(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final List<int> body;
}

/// Requests [url] the way an audio engine would.
Future<_EngineAnswer> _engineGet(
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
    return _EngineAnswer(response.statusCode, response.headers, body);
  } finally {
    client.close(force: true);
  }
}

http.StreamedResponse _audio(
  List<int> bytes, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) =>
    http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      status,
      contentLength: bytes.length,
      headers: <String, String>{'content-type': 'audio/mpeg', ...headers},
    );

extension on SubsonicStreamRelay {
  /// A publish for the sign-in the relay serves now.
  Future<Uri> publishNow(Uri upstream) =>
      publish(upstream, generation: generation);
}

void main() {
  late List<http.BaseRequest> requests;
  late SubsonicStreamRelay relay;

  SubsonicStreamRelay relayFor(
    Future<http.StreamedResponse> Function(http.BaseRequest request) answer, {
    Duration headerTimeout = const Duration(seconds: 20),
  }) {
    final SubsonicStreamRelay created = SubsonicStreamRelay(
      client: MockClient.streaming(
        (http.BaseRequest request, http.ByteStream _) {
          requests.add(request);
          return answer(request);
        },
      ),
      headerTimeout: headerTimeout,
    );
    addTearDown(created.close);
    return created;
  }

  setUp(() => requests = <http.BaseRequest>[]);

  group('publish', () {
    test('hands out a loopback address that carries no password', () async {
      relay = relayFor((_) async => _audio(<int>[1]));

      final Uri local = await relay.publishNow(_upstream);

      expect(local.scheme, 'http');
      expect(local.host, InternetAddress.loopbackIPv4.address);
      expect(local.hasQuery, isFalse);
      expect(local.toString(), isNot(contains('enc:')));
      expect(local.toString(), isNot(contains('app-password')));
      expect(local.toString(), isNot(contains('cloud.example.com')));
    });

    test('refuses anything but https', () async {
      relay = relayFor((_) async => _audio(<int>[1]));

      await expectLater(
        relay.publishNow(_upstream.replace(scheme: 'http')),
        throwsA(isA<SubsonicException>().having((SubsonicException e) => e.kind,
            'kind', SubsonicErrorKind.cleartextBlocked)),
      );
    });

    test('keeps one address per stream', () async {
      relay = relayFor((_) async => _audio(<int>[1]));

      final Uri first = await relay.publishNow(_upstream);
      final Uri again = await relay.publishNow(_upstream);
      final Uri other = await relay.publishNow(
        _upstream.replace(queryParameters: <String, String>{
          ..._upstream.queryParameters,
          'id': 's2',
        }),
      );

      expect(again, first);
      expect(other, isNot(first));
    });

    test('publishes started together share one server', () async {
      relay = relayFor((_) async => _audio(<int>[1]));

      final List<Uri> urls = await Future.wait(<Future<Uri>>[
        relay.publishNow(_upstream),
        relay.publishNow(_upstream.replace(path: '/rest/stream2.view')),
      ]);

      expect(urls[0].port, urls[1].port);
    });
  });

  group('serving the engine', () {
    test('relays the stream, asking upstream without redirects', () async {
      relay = relayFor((_) async => _audio(<int>[1, 2, 3, 4]));

      final _EngineAnswer answer =
          await _engineGet(await relay.publishNow(_upstream));

      expect(answer.status, 200);
      expect(answer.body, <int>[1, 2, 3, 4]);
      expect(answer.headers.contentType?.mimeType, 'audio/mpeg');
      final http.BaseRequest asked = requests.single;
      expect(asked.url, _upstream);
      expect(asked.followRedirects, isFalse);
      expect(asked.headers['accept-encoding'], 'identity');
    });

    test('forwards a range, so seeking works', () async {
      relay = relayFor((_) async => _audio(
            <int>[5, 6],
            status: 206,
            headers: const <String, String>{
              'content-range': 'bytes 4-5/6',
            },
          ));

      final _EngineAnswer answer = await _engineGet(
        await relay.publishNow(_upstream),
        range: 'bytes=4-',
      );

      expect(requests.single.headers['range'], 'bytes=4-');
      expect(answer.status, 206);
      expect(answer.body, <int>[5, 6]);
      expect(
          answer.headers.value(HttpHeaders.contentRangeHeader), 'bytes 4-5/6');
      expect(answer.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    });

    test('HEAD gets the headers and no body', () async {
      relay = relayFor((_) async => _audio(<int>[1, 2, 3]));

      final _EngineAnswer answer =
          await _engineGet(await relay.publishNow(_upstream), method: 'HEAD');

      expect(requests.single.method, 'HEAD');
      expect(answer.status, 200);
      expect(answer.body, isEmpty);
    });

    test('anything but GET or HEAD is refused', () async {
      relay = relayFor((_) async => _audio(<int>[1]));

      final _EngineAnswer answer =
          await _engineGet(await relay.publishNow(_upstream), method: 'POST');

      expect(answer.status, 405);
      expect(requests, isEmpty);
    });

    test('an unknown address is a 404 and asks upstream nothing', () async {
      relay = relayFor((_) async => _audio(<int>[1]));
      final Uri local = await relay.publishNow(_upstream);

      final _EngineAnswer answer = await _engineGet(
        local.replace(pathSegments: <String>['stream', 'not-a-token']),
      );

      expect(answer.status, 404);
      expect(requests, isEmpty);
    });

    test('headers copied back are only the media ones', () async {
      relay = relayFor((_) async => _audio(
            <int>[1],
            headers: const <String, String>{
              'set-cookie': 'session=abc',
              'server': 'nginx/1.2.3',
              'www-authenticate': 'Basic realm="music"',
              'etag': '"v1"',
            },
          ));

      final _EngineAnswer answer =
          await _engineGet(await relay.publishNow(_upstream));

      expect(answer.headers.value('set-cookie'), isNull);
      expect(answer.headers.value('www-authenticate'), isNull);
      expect(answer.headers.value('server'), isNot('nginx/1.2.3'));
      expect(answer.headers.value(HttpHeaders.etagHeader), '"v1"');
    });
  });

  // The engines follow redirects on their own. Through the relay, a redirect
  // is never followed: not on the first request, and not on a later one.
  group('redirects', () {
    for (final String location in <String>[
      'http://cloud.example.com/rest/stream.view?u=alice&p=enc:00&id=s1',
      'https://cdn.elsewhere.example.net/track.mp3',
      'https://cloud.example.com/other/stream.view',
    ]) {
      test('a redirect to $location is refused, not followed', () async {
        relay = relayFor((_) async => http.StreamedResponse(
              const Stream<List<int>>.empty(),
              302,
              headers: <String, String>{'location': location},
            ));

        final _EngineAnswer answer =
            await _engineGet(await relay.publishNow(_upstream));

        expect(answer.status, 502);
        expect(answer.body, isEmpty);
        expect(answer.headers.value(HttpHeaders.locationHeader), isNull);
        expect(requests, hasLength(1));
        expect(requests.single.url, _upstream);
        expect(requests.single.followRedirects, isFalse);
      });
    }

    test('a redirect on a later request, after the probe, is refused too',
        () async {
      int asked = 0;
      relay = relayFor((_) async {
        asked++;
        if (asked == 1) return _audio(<int>[1, 2]);
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          307,
          headers: const <String, String>{
            'location': 'http://evil.example.net/steal',
          },
        );
      });
      final Uri local = await relay.publishNow(_upstream);

      expect((await _engineGet(local)).status, 200);
      final _EngineAnswer seek = await _engineGet(local, range: 'bytes=1-');

      expect(seek.status, 502);
      expect(requests, hasLength(2));
      expect(
          requests.every((http.BaseRequest r) => !r.followRedirects), isTrue);
      expect(
        requests.every((http.BaseRequest r) => r.url == _upstream),
        isTrue,
      );
    });
  });

  group('nothing leaks back', () {
    test('an HTTP error keeps its status but not its body', () async {
      relay = relayFor((_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('denied for $_upstream')),
            401,
            headers: const <String, String>{'content-type': 'text/html'},
          ));

      final _EngineAnswer answer =
          await _engineGet(await relay.publishNow(_upstream));

      expect(answer.status, 401);
      expect(answer.body, isEmpty);
    });

    test('a page instead of audio is a 502', () async {
      relay = relayFor((_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('{"error": "$_upstream"}')),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ));

      final _EngineAnswer answer =
          await _engineGet(await relay.publishNow(_upstream));

      expect(answer.status, 502);
      expect(answer.body, isEmpty);
    });

    test('a compressed body is a 502', () async {
      relay = relayFor((_) async => _audio(
            <int>[1],
            headers: const <String, String>{'content-encoding': 'gzip'},
          ));

      expect((await _engineGet(await relay.publishNow(_upstream))).status, 502);
    });

    test('a transport failure naming the URL is a bare 502', () async {
      relay = relayFor(
        (_) async => throw http.ClientException('failed: $_upstream'),
      );

      final _EngineAnswer answer =
          await _engineGet(await relay.publishNow(_upstream));

      expect(answer.status, 502);
      expect(answer.body, isEmpty);
    });

    test('headers that never come are a 502', () async {
      relay = relayFor(
        (_) => Completer<http.StreamedResponse>().future,
        headerTimeout: const Duration(milliseconds: 100),
      );

      expect((await _engineGet(await relay.publishNow(_upstream))).status, 502);
    });
  });

  test('an engine that hangs up stops the upstream transfer', () async {
    final StreamController<List<int>> body = StreamController<List<int>>();
    final Completer<void> cancelled = Completer<void>();
    body.onCancel = cancelled.complete;
    relay = relayFor((_) async => http.StreamedResponse(
          body.stream,
          200,
          headers: const <String, String>{'content-type': 'audio/mpeg'},
        ));
    final Uri local = await relay.publishNow(_upstream);
    // A song that keeps coming, more than the relay buffers before it sends.
    final Timer feed = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!cancelled.isCompleted) body.add(List<int>.filled(16 * 1024, 0));
    });
    addTearDown(feed.cancel);

    final HttpClient engine = HttpClient();
    final HttpClientResponse response =
        await (await engine.getUrl(local)).close();
    await response.first;
    engine.close(force: true);

    await cancelled.future.timeout(const Duration(seconds: 5));
  });

  // Casting a password session's track: the cast relay on the LAN fetches
  // from this one, which fetches from the server, so the receiver sees
  // neither the password nor the server.
  test('casting reaches the stream through both relays', () async {
    relay = relayFor((_) async => _audio(<int>[7, 8, 9]));
    final LocalCastMediaProxy cast = LocalCastMediaProxy(
      lanAddress: () async => InternetAddress.loopbackIPv4,
    );
    addTearDown(cast.stop);
    await cast.start();

    final CastMedia relayed = cast.publish(CastMedia(
      url: await relay.publishNow(_upstream),
      contentType: 'audio/mpeg',
    ));
    final _EngineAnswer receiver = await _engineGet(relayed.url);

    expect(receiver.status, 200);
    expect(receiver.body, <int>[7, 8, 9]);
    expect(relayed.url.toString(), isNot(contains('enc:')));
    expect(requests.single.url, _upstream);
    expect(requests.single.followRedirects, isFalse);
  });

  group('revoking', () {
    test('revokeAll forgets every stream and closes the server', () async {
      relay = relayFor((_) async => _audio(<int>[1]));
      final Uri local = await relay.publishNow(_upstream);

      await relay.revokeAll();

      await expectLater(_engineGet(local), throwsA(isA<SocketException>()));
      expect(requests, isEmpty);
      // A later sign-in can stream again, from a fresh address.
      final Uri fresh = await relay.publishNow(_upstream);
      expect(fresh, isNot(local));
      expect((await _engineGet(fresh)).status, 200);
    });

    test('revoking while it starts leaves nothing serving', () async {
      final Completer<HttpServer> bound = Completer<HttpServer>();
      final SubsonicStreamRelay slow = SubsonicStreamRelay(
        client: MockClient((_) async => http.Response('', 200)),
        bind: () => bound.future,
      );
      addTearDown(slow.close);

      final Future<Uri> publishing = slow.publishNow(_upstream);
      final Future<void> revoking = slow.revokeAll();
      final HttpServer server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final int port = server.port;
      bound.complete(server);

      await expectLater(
        publishing,
        throwsA(isA<SubsonicException>().having((SubsonicException e) => e.kind,
            'kind', SubsonicErrorKind.unexpected)),
      );
      await revoking;
      await expectLater(
        _engineGet(Uri.parse('http://127.0.0.1:$port/')),
        throwsA(isA<SocketException>()),
      );
    });

    test('a publish for a sign-in revoked since is refused', () async {
      relay = relayFor((_) async => _audio(<int>[1]));
      final int signedIn = relay.generation;
      final Uri before = await relay.publish(_upstream, generation: signedIn);

      await relay.revokeAll();

      await expectLater(
        relay.publish(_upstream, generation: signedIn),
        throwsA(isA<SubsonicException>()),
      );
      // Nothing came back: a fresh sign-in's publish gets a fresh address.
      final Uri fresh = await relay.publishNow(_upstream);
      expect(fresh, isNot(before));
      expect(fresh.pathSegments.last, isNot(before.pathSegments.last));
    });

    test('a publish that resumes after a revoke registers nothing', () async {
      relay = relayFor((_) async => _audio(<int>[1]));
      await relay.publishNow(_upstream);
      final int signedIn = relay.generation;

      // The server is up, so this publish resumes on a later microtask; the
      // sign-out lands first.
      final Future<Uri> publishing =
          relay.publish(_upstream, generation: signedIn);
      final Future<void> revoking = relay.revokeAll();

      await expectLater(publishing, throwsA(isA<SubsonicException>()));
      await revoking;
    });

    test('a closed relay serves nothing again', () async {
      relay = relayFor((_) async => _audio(<int>[1]));
      await relay.close();

      await expectLater(
        relay.publishNow(_upstream),
        throwsA(isA<SubsonicException>()),
      );
    });

    test('a relay that cannot bind says so, and recovers', () async {
      int attempts = 0;
      final SubsonicStreamRelay flaky = SubsonicStreamRelay(
        client: MockClient((_) async => http.Response('', 200)),
        bind: () async {
          attempts++;
          if (attempts == 1) throw const SocketException('no loopback');
          return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        },
      );
      addTearDown(flaky.close);

      await expectLater(
        flaky.publishNow(_upstream),
        throwsA(isA<SubsonicException>()
            .having((SubsonicException e) => e.message, 'message',
                isNot(contains('loopback')))
            .having((SubsonicException e) => e.message, 'message',
                isNot(contains('cloud.example.com')))),
      );
      expect((await flaky.publishNow(_upstream)).host, '127.0.0.1');
    });
  });
}
