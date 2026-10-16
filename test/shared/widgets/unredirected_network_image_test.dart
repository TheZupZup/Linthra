import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/unredirected_network_image.dart';

/// A local server answering every request with [handle], counting them.
class _Server {
  _Server._(this._server, this.host);

  static Future<_Server> start(
    void Function(HttpRequest request, _Server self) handle, {
    String host = '127.0.0.1',
  }) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _Server self = _Server._(server, host);
    server.listen((HttpRequest request) {
      self.requests++;
      handle(request, self);
    });
    return self;
  }

  final HttpServer _server;
  final String host;
  int requests = 0;

  Uri url(String path) => Uri.parse('http://$host:${_server.port}$path');

  Future<void> close() => _server.close(force: true);
}

void main() {
  test('loads a cover served directly', () async {
    final _Server server = await _Server.start((HttpRequest request, _) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(<int>[1, 2, 3])
        ..close();
    });
    addTearDown(server.close);

    expect(await UnredirectedNetworkImage.fetch(server.url('/cover')),
        <int>[1, 2, 3]);
  });

  test('a redirect to another host is not followed', () async {
    final _Server elsewhere = await _Server.start(
      (HttpRequest request, _) => request.response
        ..add(<int>[9])
        ..close(),
      host: 'localhost',
    );
    addTearDown(elsewhere.close);
    final _Server origin = await _Server.start((HttpRequest request, _) {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader,
            elsewhere.url('/steal?p=enc:00').toString())
        ..close();
    });
    addTearDown(origin.close);

    await expectLater(
      UnredirectedNetworkImage.fetch(origin.url('/cover?p=enc:70617373')),
      throwsA(isA<UnredirectedImageException>().having(
          (UnredirectedImageException e) => e.statusCode, 'status', 302)),
    );
    expect(origin.requests, 1);
    expect(elsewhere.requests, 0);
  });

  test('nor is a redirect back to the same host', () async {
    final _Server origin = await _Server.start((HttpRequest request, self) {
      if (request.uri.path == '/cover') {
        request.response
          ..statusCode = HttpStatus.movedPermanently
          ..headers.set(HttpHeaders.locationHeader, '/other')
          ..close();
      } else {
        request.response
          ..add(<int>[1])
          ..close();
      }
    });
    addTearDown(origin.close);

    await expectLater(
      UnredirectedNetworkImage.fetch(origin.url('/cover')),
      throwsA(isA<UnredirectedImageException>()),
    );
    expect(origin.requests, 1);
  });

  test('a failure never names the URL', () async {
    final _Server origin = await _Server.start((HttpRequest request, _) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    });
    addTearDown(origin.close);
    final Uri url = origin.url('/cover?u=alice&p=enc:70617373');

    Object? notFound;
    try {
      await UnredirectedNetworkImage.fetch(url);
    } catch (error) {
      notFound = error;
    }
    await origin.close();
    Object? refused;
    try {
      await UnredirectedNetworkImage.fetch(url);
    } catch (error) {
      refused = error;
    }

    for (final Object? error in <Object?>[notFound, refused]) {
      expect(error, isA<UnredirectedImageException>());
      expect(error.toString(), isNot(contains('enc:')));
      expect(error.toString(), isNot(contains('alice')));
      expect(error.toString(), isNot(contains('127.0.0.1')));
    }
    expect((notFound! as UnredirectedImageException).statusCode, 404);
  });

  test('says nothing of its URL, and is keyed by it', () {
    final Uri url = Uri.parse('https://cloud.example.com/rest/getCoverArt.view'
        '?u=alice&p=enc:70617373&id=al-1');

    expect(UnredirectedNetworkImage(url).toString(), isNot(contains('enc:')));
    expect(UnredirectedNetworkImage(url), UnredirectedNetworkImage(url));
    expect(
      UnredirectedNetworkImage(url).hashCode,
      UnredirectedNetworkImage(url).hashCode,
    );
    expect(
      UnredirectedNetworkImage(url),
      isNot(UnredirectedNetworkImage(url.replace(path: '/other'))),
    );
  });
}
