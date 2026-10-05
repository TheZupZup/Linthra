import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_download_source.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_track_downloader.dart';

/// A configurable [JellyfinDownloadSource] that drives each download outcome
/// without a real server: verification can throw, and the minted URL can be
/// canned or absent.
class _FakeDownloadSource implements JellyfinDownloadSource {
  _FakeDownloadSource({this.verifyError, this.downloadUri});

  final JellyfinException? verifyError;
  final Uri? downloadUri;
  int verifyCount = 0;

  @override
  Future<void> verifyReachable() async {
    verifyCount++;
    final JellyfinException? error = verifyError;
    if (error != null) throw error;
  }

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => downloadUri;
}

const _track = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

/// The whole body of [data], read the way the offline cache reads it.
Future<List<int>> _bodyOf(RemoteTrackData data) async => <int>[
      for (final List<int> chunk in await data.body.toList()) ...chunk,
    ];

void main() {
  group('JellyfinTrackDownloader', () {
    test('isRemote is true only for Jellyfin tracks', () {
      final downloader = JellyfinTrackDownloader(() => null);

      expect(downloader.isRemote(_track), isTrue);
      expect(
        downloader.isRemote(
          const Track(id: '1', title: 'L', uri: '/music/x.mp3'),
        ),
        isFalse,
      );
    });

    test('verifies the session, then fetches bytes from the minted URL',
        () async {
      final uri = Uri.parse(
        'https://music.example.com/Items/t1/Download?api_key=secret-token',
      );
      final source = _FakeDownloadSource(downloadUri: uri);
      Uri? requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response.bytes(
          <int>[10, 20, 30],
          200,
          headers: <String, String>{'content-type': 'audio/flac'},
        );
      });
      final downloader =
          JellyfinTrackDownloader(() => source, httpClient: client);

      final RemoteTrackData data = await downloader.fetch(_track);

      expect(source.verifyCount, 1);
      expect(requested, uri);
      expect(await _bodyOf(data), <int>[10, 20, 30]);
      expect(data.fileExtension, 'flac');
    });

    test('maps an mpeg content type to an mp3 extension', () async {
      final source = _FakeDownloadSource(
        downloadUri: Uri.parse('https://x/Items/t1/Download?api_key=t'),
      );
      final client = MockClient((request) async {
        return http.Response.bytes(
          <int>[1],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      });

      final data =
          await JellyfinTrackDownloader(() => source, httpClient: client)
              .fetch(_track);

      expect(data.fileExtension, 'mp3');
    });

    test('throws when not signed in', () async {
      final downloader = JellyfinTrackDownloader(() => null);

      await expectLater(downloader.fetch(_track), throwsA(isA<Object>()));
    });

    test('surfaces a verification failure', () async {
      final source = _FakeDownloadSource(
        verifyError: JellyfinException.unauthorized(),
      );

      await expectLater(
        JellyfinTrackDownloader(() => source).fetch(_track),
        throwsA(isA<JellyfinException>()),
      );
    });

    test('throws when no download URL can be built', () async {
      final source = _FakeDownloadSource(downloadUri: null);

      await expectLater(
        JellyfinTrackDownloader(() => source).fetch(_track),
        throwsA(isA<Object>()),
      );
    });

    test('throws on a non-2xx response', () async {
      final source = _FakeDownloadSource(
        downloadUri: Uri.parse('https://x/Items/t1/Download?api_key=t'),
      );
      final client = MockClient((request) async => http.Response('no', 404));

      await expectLater(
        JellyfinTrackDownloader(() => source, httpClient: client).fetch(_track),
        throwsA(isA<Object>()),
      );
    });

    test('a transport failure is re-raised without leaking the tokenized URL',
        () async {
      final uri = Uri.parse(
        'https://music.example.com/Items/t1/Download?api_key=SECRET-TOKEN',
      );
      final source = _FakeDownloadSource(downloadUri: uri);
      final client = MockClient((request) async {
        // A real ClientException can embed the full (tokenized) URL.
        throw http.ClientException('Connection failed for $uri', uri);
      });
      final downloader =
          JellyfinTrackDownloader(() => source, httpClient: client);

      try {
        await downloader.fetch(_track);
        fail('expected fetch to throw');
      } catch (error) {
        expect(error.toString(), isNot(contains('SECRET-TOKEN')));
        expect(error.toString(), isNot(contains('api_key')));
      }
    });

    test('refuses a 200 login page instead of saving it as the track',
        () async {
      // A reverse-proxy/SSO login page answers 200 text/html; its bytes are
      // not the audio file and must never be handed back as the download.
      final uri = Uri.parse(
        'https://music.example.com/Items/t1/Download?api_key=SECRET-TOKEN',
      );
      final source = _FakeDownloadSource(downloadUri: uri);
      final client = MockClient((request) async {
        return http.Response(
          '<!doctype html><html><body>Sign in</body></html>',
          200,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
        );
      });
      final downloader =
          JellyfinTrackDownloader(() => source, httpClient: client);
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
              startsWith('Jellyfin download failed'),
              isNot(contains('SECRET-TOKEN')),
              isNot(contains('api_key')),
              isNot(contains('Sign in')),
            ),
          ),
        ),
      );
      // Rejected on the headers alone, before any of the body is buffered.
      expect(progress, isEmpty);
    });

    for (final String? contentType in <String?>[
      'application/octet-stream',
      'binary/octet-stream',
      null,
    ]) {
      test('keeps accepting a ${contentType ?? 'missing'} content type',
          () async {
        final source = _FakeDownloadSource(
          downloadUri: Uri.parse('https://x/Items/t1/Download?api_key=t'),
        );
        final client = MockClient((request) async {
          return http.Response.bytes(
            <int>[1, 2, 3],
            200,
            headers: <String, String>{
              if (contentType != null) 'content-type': contentType,
            },
          );
        });

        final data =
            await JellyfinTrackDownloader(() => source, httpClient: client)
                .fetch(_track);

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
        final downloader = JellyfinTrackDownloader(
          () => _FakeDownloadSource(
            downloadUri:
                Uri.parse('https://music.example.com/Items/t1/Download'),
          ),
          httpClient: client,
        );

        await expectLater(
          downloader.fetch(_track).timeout(const Duration(seconds: 5)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              startsWith('Jellyfin download failed'),
            ),
          ),
        );
        expect(cancelled, isTrue);
      });
    }
  });

  group('the body is handed back as it arrives (#745)', () {
    final Uri uri = Uri.parse(
      'https://music.example.com/Items/t1/Download?api_key=SECRET-TOKEN',
    );

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

      final RemoteTrackData data = await JellyfinTrackDownloader(
        () => _FakeDownloadSource(downloadUri: uri),
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
      final RemoteTrackData data = await JellyfinTrackDownloader(
        () => _FakeDownloadSource(downloadUri: uri),
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
              startsWith('Jellyfin download failed'),
              isNot(contains('SECRET-TOKEN')),
              isNot(contains('api_key')),
            ),
          ),
        ),
      );
    });
  });
}
