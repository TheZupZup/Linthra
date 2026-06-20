import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/sources/plex/plex_download_source.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_track_downloader.dart';

/// A configurable [PlexDownloadSource] that drives each download outcome without
/// a real server: verification can throw, and the minted URL can be canned or
/// absent.
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

const _track = Track(id: '301', title: 'Nightcall', uri: 'plex:301');

void main() {
  group('PlexTrackDownloader', () {
    test('isRemote is true only for Plex tracks', () {
      final downloader = PlexTrackDownloader(() => null);

      expect(downloader.isRemote(_track), isTrue);
      expect(
        downloader.isRemote(
          const Track(id: '1', title: 'L', uri: '/music/x.mp3'),
        ),
        isFalse,
      );
      // A sibling remote provider's track is not Plex's to fetch.
      expect(
        downloader.isRemote(
          const Track(id: 'j', title: 'J', uri: 'jellyfin:j'),
        ),
        isFalse,
      );
    });

    test('verifies the session, then fetches bytes from the minted URL',
        () async {
      final uri = Uri.parse(
        'https://plex.example.com:32400/library/parts/9001/167/file.flac'
        '?download=1&X-Plex-Token=secret-token',
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
      final downloader = PlexTrackDownloader(() => source, httpClient: client);

      final RemoteTrackData data = await downloader.fetch(_track);

      expect(source.verifyCount, 1);
      expect(requested, uri);
      expect(data.bytes, <int>[10, 20, 30]);
      expect(data.fileExtension, 'flac');
    });

    test('maps an mpeg content type to an mp3 extension', () async {
      final source = _FakeDownloadSource(
        downloadUri: Uri.parse('https://x/library/parts/1/f.mp3?download=1'),
      );
      final client = MockClient((request) async {
        return http.Response.bytes(
          <int>[1],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      });

      final data = await PlexTrackDownloader(() => source, httpClient: client)
          .fetch(_track);

      expect(data.fileExtension, 'mp3');
    });

    test('throws when not signed in', () async {
      final downloader = PlexTrackDownloader(() => null);

      await expectLater(downloader.fetch(_track), throwsA(isA<Object>()));
    });

    test('surfaces a verification failure as a typed PlexException', () async {
      final source = _FakeDownloadSource(
        verifyError: PlexException.unauthorized(),
      );

      await expectLater(
        PlexTrackDownloader(() => source).fetch(_track),
        throwsA(isA<PlexException>()),
      );
    });

    test('throws when no download URL can be built', () async {
      final source = _FakeDownloadSource(downloadUri: null);

      await expectLater(
        PlexTrackDownloader(() => source).fetch(_track),
        throwsA(isA<Object>()),
      );
    });

    test('throws on a non-2xx response', () async {
      final source = _FakeDownloadSource(
        downloadUri: Uri.parse('https://x/library/parts/1/f?download=1'),
      );
      final client = MockClient((request) async => http.Response('no', 404));

      await expectLater(
        PlexTrackDownloader(() => source, httpClient: client).fetch(_track),
        throwsA(isA<Object>()),
      );
    });

    test('a transport failure is re-raised without leaking the tokenized URL',
        () async {
      final uri = Uri.parse(
        'https://plex.example.com:32400/library/parts/9001/167/file.flac'
        '?download=1&X-Plex-Token=SECRET-TOKEN',
      );
      final source = _FakeDownloadSource(downloadUri: uri);
      final client = MockClient((request) async {
        // A real ClientException can embed the full (tokenized) URL.
        throw http.ClientException('Connection failed for $uri', uri);
      });
      final downloader = PlexTrackDownloader(() => source, httpClient: client);

      try {
        await downloader.fetch(_track);
        fail('expected fetch to throw');
      } catch (error) {
        expect(error.toString(), isNot(contains('SECRET-TOKEN')));
        expect(error.toString(), isNot(contains('X-Plex-Token')));
      }
    });
  });
}
