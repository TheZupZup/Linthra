import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';

import 'fake_subsonic_client.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'fixedsalt',
  token: 'tok-abc',
  serverType: 'navidrome',
);

void main() {
  late FakeSubsonicClient client;

  SubsonicMusicSource source() =>
      SubsonicMusicSource(session: _session, client: client);

  setUp(() => client = FakeSubsonicClient());

  test('id is the stable "subsonic"; displayName reflects the product', () {
    expect(source().id, 'subsonic');
    expect(source().displayName, 'Navidrome');
  });

  group('fetchTracks', () {
    test('walks every album and flattens its songs into tracks', () async {
      client.albums = const <SubsonicAlbumDto>[
        SubsonicAlbumDto(id: 'al-1', name: 'A'),
        SubsonicAlbumDto(id: 'al-2', name: 'B'),
      ];
      client.songsByAlbum = const <String, List<SubsonicSongDto>>{
        'al-1': <SubsonicSongDto>[
          SubsonicSongDto(id: 's1', title: 'One'),
          SubsonicSongDto(id: 's2', title: 'Two'),
        ],
        'al-2': <SubsonicSongDto>[SubsonicSongDto(id: 's3', title: 'Three')],
      };

      final tracks = await source().fetchTracks();

      expect(client.requestedAlbumIds, <String>['al-1', 'al-2']);
      expect(tracks.map((t) => t.id), <String>['s1', 's2', 's3']);
      // Every track uri is token-free.
      for (final Track t in tracks) {
        expect(t.uri, startsWith('subsonic:'));
        expect(t.uri, isNot(contains('tok-abc')));
        expect(t.uri, isNot(contains('fixedsalt')));
      }
    });
  });

  group('resolvePlayableUri', () {
    test('mints the stream URL with the credential only at play time',
        () async {
      const track = Track(id: 's1', title: 'One', uri: 'subsonic:s1');

      final uri = await source().resolvePlayableUri(track);

      expect(uri, isNotNull);
      expect(uri!.path, endsWith('/rest/stream.view'));
      expect(uri.queryParameters['id'], 's1');
      // The credential is woven into the *resolved* URL (at play time)…
      expect(uri.queryParameters['t'], 'tok-abc');
      expect(uri.queryParameters['s'], 'fixedsalt');
      expect(uri.queryParameters['u'], 'alice');
      // …and the probe ran against exactly that URL.
      expect(client.lastProbedUrl, uri);
    });

    test('classifies a rejected stream as unauthorized', () async {
      client.streamProbe = const SubsonicStreamProbe(statusCode: 401);
      const track = Track(id: 's1', title: 'One', uri: 'subsonic:s1');
      expect(
        () => source().resolvePlayableUri(track),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.unauthorized)),
      );
    });

    test('classifies an HTML proxy page as not-Subsonic', () async {
      client.streamProbe =
          const SubsonicStreamProbe(statusCode: 200, contentType: 'text/html');
      const track = Track(id: 's1', title: 'One', uri: 'subsonic:s1');
      expect(
        () => source().resolvePlayableUri(track),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.notSubsonic)),
      );
    });
  });

  group('resolveDownloadUri', () {
    test('mints the original-file download URL with the credential', () async {
      const track = Track(id: 's1', title: 'One', uri: 'subsonic:s1');

      final uri = await source().resolveDownloadUri(track);

      expect(uri!.path, endsWith('/rest/download.view'));
      expect(uri.queryParameters['id'], 's1');
      expect(uri.queryParameters['t'], 'tok-abc');
    });
  });

  test('verifyReachable delegates to the client', () async {
    await source().verifyReachable();
    expect(client.verifyCount, 1);
  });
}
