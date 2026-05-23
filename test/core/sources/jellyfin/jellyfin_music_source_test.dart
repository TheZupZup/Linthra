import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';

import 'fake_jellyfin_client.dart';

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'secret-token',
  deviceId: 'device-1',
  serverName: 'My Server',
);

JellyfinMusicSource _source(FakeJellyfinClient client) =>
    JellyfinMusicSource(session: _session, client: client);

void main() {
  group('JellyfinMusicSource', () {
    test('identifies itself as the jellyfin source', () {
      final source = _source(FakeJellyfinClient());
      expect(source.id, 'jellyfin');
      expect(source.displayName, contains('My Server'));
    });

    test('fetchTracks lists and maps audio items', () async {
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.audio: <JellyfinItemDto>[
            const JellyfinItemDto(id: 't1', name: 'One'),
            const JellyfinItemDto(id: 't2', name: 'Two'),
          ],
        },
      );

      final tracks = await _source(client).fetchTracks();

      expect(tracks.map((t) => t.title).toList(), <String>['One', 'Two']);
      expect(tracks.first.uri, 'jellyfin:t1');
      expect(client.requestedKinds, <JellyfinItemKind>[JellyfinItemKind.audio]);
    });

    test('fetchAlbums and fetchArtists request the right kinds', () async {
      final client = FakeJellyfinClient(
        itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
          JellyfinItemKind.album: <JellyfinItemDto>[
            const JellyfinItemDto(id: 'a1', name: 'Album'),
          ],
          JellyfinItemKind.artist: <JellyfinItemDto>[
            const JellyfinItemDto(id: 'ar1', name: 'Artist'),
          ],
        },
      );
      final source = _source(client);

      final albums = await source.fetchAlbums();
      final artists = await source.fetchArtists();

      expect(albums.single.title, 'Album');
      expect(artists.single.name, 'Artist');
      expect(
        client.requestedKinds,
        containsAll(<JellyfinItemKind>[
          JellyfinItemKind.album,
          JellyfinItemKind.artist,
        ]),
      );
    });

    test('resolvePlayableUri mints a stream URL with the token at play time',
        () async {
      final source = _source(FakeJellyfinClient());
      const track = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

      final uri = await source.resolvePlayableUri(track);

      expect(uri, isNotNull);
      expect(uri!.path, '/Audio/t1/universal');
      expect(uri.host, 'music.example.com');
      expect(uri.queryParameters['api_key'], 'secret-token');
      expect(uri.queryParameters['UserId'], 'user-1');
      expect(uri.queryParameters['DeviceId'], 'device-1');
    });

    test('resolvePlayableUri falls back to the track id when uri is unprefixed',
        () async {
      final source = _source(FakeJellyfinClient());
      const track = Track(id: 'raw-id', title: 'One', uri: 'something-else');

      final uri = await source.resolvePlayableUri(track);

      expect(uri!.path, '/Audio/raw-id/universal');
    });
  });
}
