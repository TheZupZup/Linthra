import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/native/rust_http_client.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';

/// Requests through the Rust core, against a server on the loopback. TLS is
/// proven on the Rust side (native/linthra_core/tests/tls_*.rs); these check
/// what `package:http` callers rely on.
void main() {
  late HttpServer server;
  late String base;
  final List<HttpRequest> seen = <HttpRequest>[];
  final List<String> bodies = <String>[];
  late Future<void> Function(HttpRequest request) handle;

  setUp(() async {
    seen.clear();
    bodies.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      seen.add(request);
      bodies.add(await utf8.decoder.bind(request).join());
      await handle(request);
    });
  });
  tearDown(() => server.close(force: true));

  final RustHttpClient client = RustHttpClient();

  test('a GET brings back the status, the headers and the body', () async {
    handle = (HttpRequest request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..headers.add('x-one', 'a')
        ..write('{"ok":true}');
      await request.response.close();
    };
    final http.Response response = await client.get(
      Uri.parse('$base/rest/ping.view?u=alice&t=tok'),
      headers: <String, String>{'Accept': 'application/json'},
    );
    expect(response.statusCode, 200);
    expect(response.body, '{"ok":true}');
    expect(response.headers['content-type'], startsWith('application/json'));
    expect(response.headers['x-one'], 'a');
    expect(seen.single.uri.queryParameters['t'], 'tok');
    expect(seen.single.headers.value('accept'), 'application/json');
  });

  test('a POST carries its body and content type', () async {
    handle = (HttpRequest request) async {
      await request.response.close();
    };
    await client.post(
      Uri.parse('$base/rest/createPlaylist.view'),
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'u=alice&songId=1&songId=2',
    );
    expect(seen.single.method, 'POST');
    expect(bodies.single, 'u=alice&songId=1&songId=2');
    expect(
      seen.single.headers.contentType?.mimeType,
      'application/x-www-form-urlencoded',
    );
  });

  test('an error status is an answer, not a failure', () async {
    handle = (HttpRequest request) async {
      request.response
        ..statusCode = 503
        ..write('down');
      await request.response.close();
    };
    final http.Response response = await client.get(Uri.parse('$base/x'));
    expect(response.statusCode, 503);
    expect(response.body, 'down');
  });

  test('a redirect is followed, unless the request says not to', () async {
    handle = (HttpRequest request) async {
      if (request.uri.path == '/old') {
        request.response
          ..statusCode = 302
          ..headers.set('location', '/new');
      } else {
        request.response.write('moved here');
      }
      await request.response.close();
    };
    final http.Response followed = await client.get(Uri.parse('$base/old'));
    expect(followed.statusCode, 200);
    expect(followed.body, 'moved here');

    seen.clear();
    final http.Request held = http.Request('GET', Uri.parse('$base/old'))
      ..followRedirects = false;
    final http.Response kept =
        await http.Response.fromStream(await client.send(held));
    expect(kept.statusCode, 302);
    expect(seen.map((HttpRequest r) => r.uri.path), <String>['/old']);
  });

  test('a server that is not there is a ClientException without the URL',
      () async {
    final int port = server.port;
    await server.close(force: true);
    await expectLater(
      client.get(Uri.parse('http://127.0.0.1:$port/rest?t=secret-token')),
      throwsA(
        isA<http.ClientException>().having(
          (http.ClientException e) => e.toString(),
          'text',
          isNot(contains('secret-token')),
        ),
      ),
    );
  });

  test(
      'a stream probe reads the headers only, from a server that ignores '
      'the range', () async {
    // A transcode streams the whole track whatever the range says; this one
    // never stops. The probe must come back with the headers and let go: a
    // raw socket, so the server sees the connection close.
    final ServerSocket raw =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(raw.close);
    final Completer<void> connectionDropped = Completer<void>();
    final Completer<String> requestHead = Completer<String>();
    int sent = 0;
    raw.listen((Socket socket) async {
      void dropped() {
        if (!connectionDropped.isCompleted) connectionDropped.complete();
      }

      unawaited(socket.done.then((_) => dropped(), onError: (_) => dropped()));
      socket.listen(
        (List<int> data) {
          if (!requestHead.isCompleted) {
            requestHead.complete(latin1.decode(data));
          }
        },
        onDone: dropped,
        onError: (Object _) => dropped(),
      );
      socket.add(
          latin1.encode('HTTP/1.1 200 OK\r\ncontent-type: audio/mpeg\r\n\r\n'));
      final List<int> chunk = List<int>.filled(64 * 1024, 7);
      while (!connectionDropped.isCompleted) {
        try {
          socket.add(chunk);
          sent += chunk.length;
          await socket.flush().timeout(const Duration(milliseconds: 200));
        } catch (_) {
          dropped();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    final HttpSubsonicClient subsonic = HttpSubsonicClient(httpClient: client);
    final SubsonicStreamProbe probe = await subsonic.probeStream(
      Uri.parse('http://127.0.0.1:${raw.port}/rest/stream.view?id=1'),
    );
    expect(probe.statusCode, 200);
    expect(probe.contentType, 'audio/mpeg');
    expect(
        (await requestHead.future).toLowerCase(), contains('range: bytes=0-1'));
    await connectionDropped.future.timeout(const Duration(seconds: 10));
    // Bounded by socket buffers, not the track.
    expect(sent, lessThan(16 * 1024 * 1024));
  });

  test('the Subsonic client works end to end through it', () async {
    handle = (HttpRequest request) async {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{
          'subsonic-response': <String, Object?>{
            'status': 'ok',
            'version': '1.16.1',
            'type': 'navidrome',
            'serverVersion': '0.53.0',
          },
        }));
      await request.response.close();
    };
    final HttpSubsonicClient subsonic = HttpSubsonicClient(httpClient: client);
    final SubsonicServerInfo info = await subsonic.ping(
      base,
      username: 'alice',
      credentials: const SubsonicCredentials(salt: 's', token: 't'),
    );
    expect(info.type, 'navidrome');
    expect(seen.single.uri.path, '/rest/ping.view');
  });

  test('an unreachable server reads as one to the Subsonic client', () async {
    final int port = server.port;
    await server.close(force: true);
    const SubsonicSession session = SubsonicSession(
      baseUrl: 'http://127.0.0.1:1',
      username: 'alice',
      salt: 's',
      token: 't',
    );
    expect(port, isNot(1));
    await expectLater(
      HttpSubsonicClient(httpClient: client).verifySession(session),
      throwsA(
        isA<SubsonicException>().having(
          (SubsonicException e) => e.kind,
          'kind',
          SubsonicErrorKind.notReachable,
        ),
      ),
    );
  });

  test('Linux sends Subsonic requests through Rust, Android does not yet', () {
    http.Client transport(HostPlatform host) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[hostPlatformProvider.overrideWithValue(host)],
      );
      addTearDown(container.dispose);
      return container.read(subsonicTransportProvider)();
    }

    expect(transport(HostPlatform.linux), isA<RustHttpClient>());
    expect(transport(HostPlatform.android), isNot(isA<RustHttpClient>()));
  });
}
