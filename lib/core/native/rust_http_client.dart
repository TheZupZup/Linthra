import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api/http.dart' as rust;
import 'linthra_bridge.dart';

/// A `package:http` client whose requests go out through the Rust core
/// (native/linthra_core/src/http/), with TLS checked by the platform's trust
/// store: the server clients keep their own code and swap only how a request
/// travels.
///
/// The body streams as Rust reads it, and cancelling the response's stream
/// stops the read there: a probe that only wants the status and headers of a
/// track never downloads it, even from a server that ignores the range.
///
/// A failure is a [http.ClientException] that says what kind it was and
/// never carries the URL, which can hold credentials. A TLS failure reads as
/// one (`handshake`, `certificate`) to the clients' classifiers.
class RustHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await LinthraBridgeLoader.ensureReady();
    final Uint8List body = await request.finalize().toBytes();
    final Stream<rust.HttpPart> parts = rust.httpFetch(
      method: request.method,
      url: request.url.toString(),
      headers: <rust.HttpHeader>[
        for (final MapEntry<String, String> header in request.headers.entries)
          rust.HttpHeader(name: header.key, value: header.value),
      ],
      body: body.isEmpty && request.method == 'GET' ? null : body,
      followRedirects: request.followRedirects,
    );

    final Completer<http.StreamedResponse> head =
        Completer<http.StreamedResponse>();
    late final StreamSubscription<rust.HttpPart> subscription;
    final StreamController<List<int>> bodyStream = StreamController<List<int>>(
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      // Cancelling the body cancels the Rust stream, which stops the read.
      onCancel: () => subscription.cancel(),
    );
    subscription = parts.listen(
      (rust.HttpPart part) {
        final rust.HttpFailure? failure = part.failure;
        if (!head.isCompleted) {
          if (failure != null) {
            head.completeError(_exception(failure));
            subscription.cancel();
            return;
          }
          head.complete(
            http.StreamedResponse(
              bodyStream.stream,
              part.status ?? 0,
              headers: _headers(part.headers),
              request: request,
            ),
          );
          return;
        }
        if (failure != null) {
          bodyStream.addError(_exception(failure));
          bodyStream.close();
          return;
        }
        bodyStream.add(part.chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        final http.ClientException failed =
            http.ClientException('The request failed in the Rust core');
        if (!head.isCompleted) {
          head.completeError(failed, stackTrace);
        } else {
          bodyStream.addError(failed, stackTrace);
        }
      },
      onDone: () {
        if (!head.isCompleted) {
          head.completeError(
            http.ClientException('The connection closed without an answer'),
          );
        }
        bodyStream.close();
      },
      cancelOnError: true,
    );
    return head.future;
  }

  /// [headers] as `package:http` keeps them: lower-cased names, repeated
  /// ones joined with a comma.
  static Map<String, String> _headers(List<rust.HttpHeader> headers) {
    final Map<String, String> joined = <String, String>{};
    for (final rust.HttpHeader header in headers) {
      final String name = header.name.toLowerCase();
      final String? before = joined[name];
      joined[name] = before == null ? header.value : '$before, ${header.value}';
    }
    return joined;
  }

  static http.ClientException _exception(rust.HttpFailure failure) =>
      http.ClientException(switch (failure) {
        rust.HttpFailure.insecure =>
          'TLS handshake failed: the server certificate is not trusted',
        rust.HttpFailure.timedOut => 'The request timed out',
        rust.HttpFailure.unreachable => 'The server could not be reached',
        rust.HttpFailure.badResponse => 'The server sent an invalid answer',
        rust.HttpFailure.badRequest => 'The request could not be made',
      });
}
