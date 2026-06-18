import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/sources/plex/plex_download_source.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_track_downloader.dart';

class _FakeDownloadSource implements PlexDownloadSource {
  _FakeDownloadSource({this.verifyError, this.downloadUri});

  final PlexException? verifyError;
  final Uri? downloadUri;
  int verifyCount = 0;

  @override
  Future<void> verifyReachable() async {
    verifyCount++;
    final PlexException? error = verifyError;
    if (error != null) throw error;
  }

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => downloadUri;
}

const Track _track = Track(id: '301', title: 'Nightcall', uri: 'plex:301');
final Uri _downloadUri = Uri.parse(
  'https://plex.example.com/library/parts/9001/file.flac?X-Plex-Token=secret',
);

void main() {
  group('PlexTrackDownloader', () {
    test('isRemote is true only for Plex tracks', () {
      final PlexTrackDownloader downloader = PlexTrackDownloader(() => null);

      expect(downloader.isRemote(_track), isTrue);
      expect(
        downloader.isRemote(const Track(id: 'l', title: 'x', uri: '/a.mp3')),
        isFalse,
      );
    });

    test('verifies the session, then fetches bytes from the minted URL',
        () async {
      final _FakeDownloadSource source =
          _FakeDownloadSource(downloadUri: _downloadUri);
      Uri? requested;
      final MockClient client = MockClient((http.Request request) async {
        requested = request.url;
        return http.Response(
          'audio-bytes',
          200,
          headers: const <String, String>{'content-type': 'audio/flac'},
        );
      });
      final PlexTrackDownloader downloader = PlexTrackDownloader(
        () => source,
        httpClient: client,
      );

      final RemoteTrackData data = await downloader.fetch(_track);

      expect(source.verifyCount, 1);
      expect(requested, _downloadUri);
      expect(utf8.decode(data.bytes), 'audio-bytes');
      expect(data.fileExtension, 'flac');
    });

    test('maps an mpeg content type to an mp3 extension', () async {
      final MockClient client = MockClient((_) async {
        return http.Response.bytes(
          <int>[1],
          200,
          headers: const <String, String>{'content-type': 'audio/mpeg'},
        );
      });
      final PlexTrackDownloader downloader = PlexTrackDownloader(
        () => _FakeDownloadSource(downloadUri: _downloadUri),
        httpClient: client,
      );

      final RemoteTrackData data = await downloader.fetch(_track);

      expect(data.fileExtension, 'mp3');
    });

    test('throws when not signed in', () async {
      final PlexTrackDownloader downloader = PlexTrackDownloader(() => null);

      await expectLater(downloader.fetch(_track), throwsA(isA<StateError>()));
    });

    test('surfaces a verification failure', () async {
      final _FakeDownloadSource source = _FakeDownloadSource(
        verifyError: PlexException.unauthorized(),
      );

      await expectLater(
        PlexTrackDownloader(() => source).fetch(_track),
        throwsA(isA<PlexException>()),
      );
    });

    test('throws when no download URL can be built', () async {
      final _FakeDownloadSource source = _FakeDownloadSource(downloadUri: null);

      await expectLater(
        PlexTrackDownloader(() => source).fetch(_track),
        throwsA(isA<StateError>()),
      );
    });

    test('throws on a non-2xx response', () async {
      final MockClient client = MockClient((_) async => http.Response('no', 404));
      final PlexTrackDownloader downloader = PlexTrackDownloader(
        () => _FakeDownloadSource(downloadUri: _downloadUri),
        httpClient: client,
      );

      await expectLater(downloader.fetch(_track), throwsA(isA<StateError>()));
    });

    test('a transport failure is re-raised without leaking the tokenized URL',
        () async {
      final MockClient client = MockClient(
        (_) async => throw http.ClientException(
          'failed talking to $_downloadUri',
          _downloadUri,
        ),
      );
      final PlexTrackDownloader downloader = PlexTrackDownloader(
        () => _FakeDownloadSource(downloadUri: _downloadUri),
        httpClient: client,
      );

      try {
        await downloader.fetch(_track);
        fail('expected fetch to throw');
      } catch (error) {
        expect(error.toString(), isNot(contains('secret')));
        expect(error.toString(), isNot(contains('X-Plex-Token')));
        expect(error.toString(), isNot(contains('plex.example.com')));
      }
    });
  });
}
