// A download body that stops arriving is given up on, and only then.
//
// The remote downloaders (Jellyfin, Subsonic, Plex) hand the offline cache a
// body that is still arriving (#745), through downloadResponseBody: each
// chunk may take up to the stall timeout, and any error the body raises is
// replaced by a StateError carrying only the downloader's own message, since
// a TimeoutException or a ClientException can carry the tokenized URL. Without
// the timeout, a server that stops sending mid-body holds the download, and
// its scheduler slot, for good; a timeout that never restarts would cut off a
// slow but healthy download.
//
// Run under fake time (testWidgets), so the minutes pass at once.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/sources/download_response_body.dart';

const String _failure = 'Jellyfin download failed.';
const Duration _stall = Duration(minutes: 5);

/// One response body, fed by the test a chunk at a time.
class _Body {
  _Body() {
    _controller = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
  }

  late final StreamController<List<int>> _controller;

  /// Whoever read the body stopped listening to it.
  bool cancelled = false;

  void add(List<int> chunk) => _controller.add(chunk);

  void end() => unawaited(_controller.close());

  http.StreamedResponse response({int? contentLength}) => http.StreamedResponse(
        _controller.stream,
        200,
        contentLength: contentLength,
        headers: const <String, String>{'content-type': 'audio/flac'},
      );
}

/// What a reader of the body saw, read the way the offline cache's
/// `await for` reads it: it stops at the first error.
class _Reader {
  _Reader(RemoteTrackData data) {
    data.body.listen(
      received.addAll,
      onError: errors.add,
      onDone: () => done = true,
      cancelOnError: true,
    );
  }

  final List<int> received = <int>[];
  final List<Object> errors = <Object>[];
  bool done = false;
}

RemoteTrackData _wrap(_Body body, {int? contentLength = 8}) =>
    downloadResponseBody(
      body.response(contentLength: contentLength),
      failure: _failure,
      stallTimeout: _stall,
    );

/// Advances fake time by [by], then lets the body's last event reach the
/// reader.
///
/// A timed-out stream's error, or its end, reaches a reader that stops there
/// only once the stream's cancel has finished, and that finishes in a root
/// zone microtask, which fake time never runs on its own. An empty
/// [WidgetTester.runAsync] lets it run; nothing waits on real time.
Future<void> _advance(WidgetTester tester,
    [Duration by = Duration.zero]) async {
  await tester.pump(by);
  await tester.runAsync<void>(() async {});
  await tester.pump();
}

Matcher get _theFailure => isA<StateError>().having(
      (StateError e) => e.message,
      'message',
      _failure,
    );

void main() {
  group('the stall timeout', () {
    testWidgets('a body that keeps arriving is never stopped', (tester) async {
      final _Body body = _Body();
      final _Reader reader = _Reader(_wrap(body));

      body.add(const <int>[1, 2]);
      await _advance(tester, const Duration(minutes: 4));
      expect(reader.errors, isEmpty);

      // Each chunk starts the wait again: eight minutes after the first chunk
      // is only four after the last.
      body.add(const <int>[3, 4]);
      await _advance(tester, const Duration(minutes: 4));
      expect(reader.errors, isEmpty);

      body
        ..add(const <int>[5, 6, 7, 8])
        ..end();
      await _advance(tester);
      // Ended, the body is not timed out afterwards either.
      await _advance(tester, const Duration(minutes: 10));

      expect(reader.errors, isEmpty);
      expect(reader.done, isTrue);
      expect(reader.received, <int>[1, 2, 3, 4, 5, 6, 7, 8]);
    });

    testWidgets('silence past the timeout fails with only the failure text',
        (tester) async {
      final _Body body = _Body();
      final _Reader reader = _Reader(_wrap(body));

      body.add(const <int>[1, 2]);
      await _advance(tester, _stall - const Duration(seconds: 1));
      expect(reader.errors, isEmpty);

      await _advance(tester, const Duration(seconds: 2));

      expect(reader.received, <int>[1, 2]);
      expect(reader.errors.single, _theFailure);
      // The reader stopped, so the connection is let go rather than held.
      expect(body.cancelled, isTrue);
      expect(reader.done, isFalse);
    });

    testWidgets('a body that never sends its first chunk times out too',
        (tester) async {
      final _Body body = _Body();
      final _Reader reader = _Reader(_wrap(body));

      await _advance(tester, _stall - const Duration(seconds: 1));
      expect(reader.errors, isEmpty);

      await _advance(tester, const Duration(seconds: 2));

      expect(reader.received, isEmpty);
      expect(reader.errors.single, _theFailure);
      expect(body.cancelled, isTrue);
    });
  });

  group('the announced length', () {
    test('a Content-Length of zero reads as unknown', () {
      expect(_wrap(_Body(), contentLength: 0).length, isNull);
    });

    test('no Content-Length reads as unknown', () {
      expect(_wrap(_Body(), contentLength: null).length, isNull);
    });

    test('a Content-Length is passed on as the length', () {
      final RemoteTrackData data = _wrap(_Body(), contentLength: 8);

      expect(data.length, 8);
      expect(data.fileExtension, 'flac');
    });
  });
}
