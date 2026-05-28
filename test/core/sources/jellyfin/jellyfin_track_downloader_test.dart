import 'dart:async';

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

      final RemoteTrackDownload data = await downloader.open(_track);

      expect(source.verifyCount, 1);
      expect(requested, uri);
      expect(await _collect(data.chunks), <int>[10, 20, 30]);
      expect(data.contentLength, 3);
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
              .open(_track);

      expect(await _collect(data.chunks), <int>[1]);
      expect(data.fileExtension, 'mp3');
    });

    test('throws when not signed in', () async {
      final downloader = JellyfinTrackDownloader(() => null);

      await expectLater(downloader.open(_track), throwsA(isA<Object>()));
    });

    test('surfaces a verification failure', () async {
      final source = _FakeDownloadSource(
        verifyError: JellyfinException.unauthorized(),
      );

      await expectLater(
        JellyfinTrackDownloader(() => source).open(_track),
        throwsA(isA<JellyfinException>()),
      );
    });

    test('throws when no download URL can be built', () async {
      final source = _FakeDownloadSource(downloadUri: null);

      await expectLater(
        JellyfinTrackDownloader(() => source).open(_track),
        throwsA(isA<Object>()),
      );
    });

    test('throws on a non-2xx response', () async {
      final source = _FakeDownloadSource(
        downloadUri: Uri.parse('https://x/Items/t1/Download?api_key=t'),
      );
      final client = MockClient((request) async => http.Response('no', 404));

      await expectLater(
        JellyfinTrackDownloader(() => source, httpClient: client).open(_track),
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
        await downloader.open(_track);
        fail('expected open to throw');
      } catch (error) {
        expect(error.toString(), isNot(contains('SECRET-TOKEN')));
        expect(error.toString(), isNot(contains('api_key')));
      }
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> chunks) async {
  final List<int> bytes = <int>[];
  await for (final List<int> chunk in chunks) {
    bytes.addAll(chunk);
  }
  return bytes;
}
