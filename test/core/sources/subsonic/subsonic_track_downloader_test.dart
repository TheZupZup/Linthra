import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_track_downloader.dart';

class _FakeStreamSource implements SubsonicStreamSource {
  _FakeStreamSource({this.downloadUri});

  Uri? downloadUri;

  @override
  Future<void> verifyReachable() async {}

  @override
  Future<Uri?> resolvePlayableUri(Track track) async => downloadUri;

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => downloadUri;
}

const _track = Track(id: 's1', title: 'One', uri: 'subsonic:s1');
final _downloadUri = Uri.parse(
  'https://music.example.com/rest/download.view?id=s1&t=secret-token&s=salt1',
);

/// The whole body of [data], read the way the offline cache reads it.
Future<List<int>> _bodyOf(RemoteTrackData data) async => <int>[
      for (final List<int> chunk in await data.body.toList()) ...chunk,
    ];

void main() {
  test('isRemote is true only for subsonic tracks', () {
    final downloader = SubsonicTrackDownloader(() => _FakeStreamSource());
    expect(downloader.isRemote(_track), isTrue);
    expect(
      downloader.isRemote(const Track(id: 'l', title: 'x', uri: '/a.mp3')),
      isFalse,
    );
  });

  test('fetches the bytes and infers the extension from the content type',
      () async {
    final mock = MockClient((http.Request request) async {
      return http.Response(
        'audio-bytes',
        200,
        headers: const <String, String>{'content-type': 'audio/flac'},
      );
    });
    final downloader = SubsonicTrackDownloader(
      () => _FakeStreamSource(downloadUri: _downloadUri),
      httpClient: mock,
    );

    final data = await downloader.fetch(_track);

    expect(utf8.decode(await _bodyOf(data)), 'audio-bytes');
    expect(data.fileExtension, 'flac');
  });

  test('throws a generic, token-free error on a transport failure', () async {
    final mock = MockClient(
      (_) async =>
          throw http.ClientException('failed talking to $_downloadUri'),
    );
    final downloader = SubsonicTrackDownloader(
      () => _FakeStreamSource(downloadUri: _downloadUri),
      httpClient: mock,
    );

    await expectLater(
      downloader.fetch(_track),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          isNot(contains('secret-token')),
        ),
      ),
    );
  });

  test('throws when not signed in', () async {
    final downloader = SubsonicTrackDownloader(() => null);
    await expectLater(downloader.fetch(_track), throwsA(isA<StateError>()));
  });

  group('a 200 that is not the audio file', () {
    // download.view refuses (no download permission, downloads disabled, a
    // song deleted since the last sync) with HTTP 200 and a subsonic-response
    // error document; a reverse-proxy/SSO login page is a 200 too. None of
    // them may be handed back as the track's bytes.
    const Map<String, (String, String)> documents = <String, (String, String)>{
      'a JSON subsonic-response error': (
        'application/json; charset=utf-8',
        '{"subsonic-response":{"status":"failed","version":"1.16.1",'
            '"error":{"code":70,"message":"The requested data was not found"}}}',
      ),
      'an XML subsonic-response error': (
        'text/xml; charset=utf-8',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<subsonic-response xmlns="http://subsonic.org/restapi" '
            'status="failed" version="1.16.1">'
            '<error code="50" message="User is not authorized"/>'
            '</subsonic-response>',
      ),
      'a reverse-proxy login page': (
        'text/html; charset=utf-8',
        '<!doctype html><html><body>Sign in</body></html>',
      ),
    };

    for (final MapEntry<String, (String, String)> entry in documents.entries) {
      test('refuses ${entry.key} with a friendly, credential-free error',
          () async {
        final (String contentType, String body) = entry.value;
        final mock = MockClient((http.Request request) async {
          return http.Response(
            body,
            200,
            headers: <String, String>{'content-type': contentType},
          );
        });
        final downloader = SubsonicTrackDownloader(
          () => _FakeStreamSource(downloadUri: _downloadUri),
          httpClient: mock,
        );
        final List<int> progress = <int>[];

        await expectLater(
          downloader.fetch(
            _track,
            onProgress: (int received, int? total) => progress.add(received),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                startsWith('Download failed'),
                isNot(contains('secret-token')),
                isNot(contains('salt1')),
                isNot(contains('music.example.com')),
                isNot(contains('subsonic-response')),
                isNot(contains('html')),
              ),
            ),
          ),
        );
        // Rejected on the headers alone: the body is never buffered, so no
        // progress is reported for bytes that would only be thrown away.
        expect(progress, isEmpty);
      });
    }
  });

  group('keeps accepting what can be the audio file', () {
    // Servers label media inconsistently, and the engine sniffs the container,
    // so only document types are refused; any other type, or none, is kept.
    const Map<String, String?> accepted = <String, String?>{
      'audio/mpeg': 'audio/mpeg',
      'application/octet-stream': 'application/octet-stream',
      'application/ogg': 'application/ogg',
      'an unusual binary type': 'binary/octet-stream',
      'a missing content type': null,
    };

    for (final MapEntry<String, String?> entry in accepted.entries) {
      test(entry.key, () async {
        final String? contentType = entry.value;
        final mock = MockClient((http.Request request) async {
          return http.Response.bytes(
            <int>[1, 2, 3],
            200,
            headers: <String, String>{
              if (contentType != null) 'content-type': contentType,
            },
          );
        });
        final downloader = SubsonicTrackDownloader(
          () => _FakeStreamSource(downloadUri: _downloadUri),
          httpClient: mock,
        );

        final data = await downloader.fetch(_track);

        expect(await _bodyOf(data), <int>[1, 2, 3]);
      });
    }
  });

  group('a refused response whose body never ends', () {
    // A server that sends the headers and then stalls, or keeps a chunked
    // body open, must not hold the download (and its scheduler slot) open:
    // the refusal cancels the body instead of reading it to the end.
    for (final (String what, int status) in <(String, int)>[
      ('a 200 login page', 200),
      ('an error status', 503),
    ]) {
      test('fails at once for $what', () async {
        bool cancelled = false;
        final StreamController<List<int>> body = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        )..add(utf8.encode('<!doctype html><html><body>Sign in'));
        addTearDown(body.close);
        final client = MockClient.streaming(
          (http.BaseRequest request, http.ByteStream _) async =>
              http.StreamedResponse(
            body.stream,
            status,
            headers: <String, String>{
              'content-type': 'text/html; charset=utf-8',
            },
          ),
        );
        final downloader = SubsonicTrackDownloader(
          () => _FakeStreamSource(downloadUri: _downloadUri),
          httpClient: client,
        );

        await expectLater(
          downloader.fetch(_track).timeout(const Duration(seconds: 5)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              startsWith('Download failed'),
            ),
          ),
        );
        expect(cancelled, isTrue);
      });
    }
  });

  group('the body is handed back as it arrives (#745)', () {
    final Uri uri = _downloadUri;

    test('fetch returns before the body has arrived', () async {
      final StreamController<List<int>> body = StreamController<List<int>>();
      addTearDown(body.close);
      final MockClient client = MockClient.streaming(
        (http.BaseRequest request, http.ByteStream _) async =>
            http.StreamedResponse(
          body.stream,
          200,
          contentLength: 8,
          headers: <String, String>{'content-type': 'audio/flac'},
        ),
      );

      final RemoteTrackData data = await SubsonicTrackDownloader(
        () => _FakeStreamSource(downloadUri: uri),
        httpClient: client,
      ).fetch(_track).timeout(const Duration(seconds: 5));

      expect(data.length, 8);
      expect(data.fileExtension, 'flac');
      final Future<List<int>> read = _bodyOf(data);
      body
        ..add(<int>[1, 2, 3, 4])
        ..add(<int>[5, 6, 7, 8]);
      await body.close();
      expect(await read, <int>[1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('an error while it arrives does not leak the URL', () async {
      final StreamController<List<int>> body = StreamController<List<int>>();
      addTearDown(body.close);
      final MockClient client = MockClient.streaming(
        (http.BaseRequest request, http.ByteStream _) async =>
            http.StreamedResponse(
          body.stream,
          200,
          headers: <String, String>{'content-type': 'audio/flac'},
        ),
      );
      final RemoteTrackData data = await SubsonicTrackDownloader(
        () => _FakeStreamSource(downloadUri: uri),
        httpClient: client,
      ).fetch(_track);

      final Future<List<int>> read = _bodyOf(data);
      body
        ..add(<int>[1, 2])
        // A real ClientException can embed the full (credentialed) URL.
        ..addError(http.ClientException('Connection closed for $uri', uri));

      await expectLater(
        read,
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(
              startsWith('Download failed'),
              isNot(contains('secret-token')),
              isNot(contains('t=secret')),
            ),
          ),
        ),
      );
    });
  });
}
