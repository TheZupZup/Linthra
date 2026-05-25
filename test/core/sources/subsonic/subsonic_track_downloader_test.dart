import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/track.dart';
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

    expect(utf8.decode(data.bytes), 'audio-bytes');
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
}
