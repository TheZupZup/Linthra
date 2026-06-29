import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
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

    group('fetchLibraryForSync', () {
      test('returns mapped tracks plus the skipped count', () async {
        final client = FakeJellyfinClient(
          itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
            JellyfinItemKind.audio: <JellyfinItemDto>[
              const JellyfinItemDto(id: 't1', name: 'One'),
              const JellyfinItemDto(id: 't2', name: 'Two'),
            ],
            JellyfinItemKind.album: <JellyfinItemDto>[
              const JellyfinItemDto(id: 'a1', name: 'Album'),
            ],
            JellyfinItemKind.artist: <JellyfinItemDto>[
              const JellyfinItemDto(id: 'ar1', name: 'Artist'),
            ],
          },
        );
        client.skippedByKind = <JellyfinItemKind, int>{
          JellyfinItemKind.audio: 3,
        };

        final library = await _source(client).fetchLibraryForSync();

        expect(library.tracks.map((t) => t.id).toList(), <String>['t1', 't2']);
        expect(library.albums.single.title, 'Album');
        expect(library.artists.single.name, 'Artist');
        expect(library.skippedCount, 3);
      });

      test('albums/artists are best-effort — a failure there keeps the tracks',
          () async {
        final client = FakeJellyfinClient(
          itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
            JellyfinItemKind.audio: <JellyfinItemDto>[
              const JellyfinItemDto(id: 't1', name: 'One'),
            ],
          },
          // Tracks succeed; the secondary album/artist reads fail.
        );
        client.errorByKind = <JellyfinItemKind, JellyfinException>{
          JellyfinItemKind.album: JellyfinException.serverError(500),
          JellyfinItemKind.artist: JellyfinException.serverError(500),
        };

        final library = await _source(client).fetchLibraryForSync();

        expect(library.tracks.single.id, 't1');
        expect(library.albums, isEmpty);
        expect(library.artists, isEmpty);
      });

      test('a tracks failure propagates (so the caller preserves the catalog)',
          () async {
        final client = FakeJellyfinClient(
          itemsError: JellyfinException.unauthorized(),
        );

        await expectLater(
          _source(client).fetchLibraryForSync(),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.unauthorized,
          )),
        );
      });
    });

    test(
        'resolvePlayableUri mints a direct-stream URL with the token at play '
        'time', () async {
      final client = FakeJellyfinClient();
      final source = _source(client);
      const track = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

      final uri = await source.resolvePlayableUri(track);

      expect(uri, isNotNull);
      // The direct-play stream endpoint (static=true serves the original file),
      // not the download or universal/transcode endpoint.
      expect(uri!.path, '/Audio/t1/stream');
      expect(uri.queryParameters['static'], 'true');
      expect(uri.host, 'music.example.com');
      expect(uri.queryParameters['api_key'], 'secret-token');
      expect(uri.queryParameters['UserId'], 'user-1');
      expect(uri.queryParameters['DeviceId'], 'device-1');
      // The stream URL is probed before it is returned (and the probe sees the
      // tokenized URL the engine will fetch).
      expect(client.lastProbedUrl, uri);
    });

    test('resolvePlayableUri falls back to the track id when uri is unprefixed',
        () async {
      final source = _source(FakeJellyfinClient());
      const track = Track(id: 'raw-id', title: 'One', uri: 'something-else');

      final uri = await source.resolvePlayableUri(track);

      expect(uri!.path, '/Audio/raw-id/stream');
    });

    group('resolvePlayableUri probes the stream before returning it', () {
      const track = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

      test('an HTML/Cloudflare page maps to a web-page error', () async {
        final source = _source(FakeJellyfinClient(
          streamProbe: const JellyfinStreamProbe(
              statusCode: 200, contentType: 'text/html'),
        ));

        await expectLater(
          source.resolvePlayableUri(track),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.webPage,
          )),
        );
      });

      test('a 401 maps to unauthorized (an expired token)', () async {
        final source = _source(FakeJellyfinClient(
          streamProbe: const JellyfinStreamProbe(statusCode: 401),
        ));

        await expectLater(
          source.resolvePlayableUri(track),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.unauthorized,
          )),
        );
      });

      test('a non-audio content type maps to "not an audio stream"', () async {
        final source = _source(FakeJellyfinClient(
          streamProbe: const JellyfinStreamProbe(
            statusCode: 200,
            contentType: 'application/json',
          ),
        ));

        await expectLater(
          source.resolvePlayableUri(track),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.notAudioStream,
          )),
        );
      });

      test('a 206 audio response is accepted and the URL returned', () async {
        final source = _source(FakeJellyfinClient(
          streamProbe: const JellyfinStreamProbe(
            statusCode: 206,
            contentType: 'audio/flac',
          ),
        ));

        final uri = await source.resolvePlayableUri(track);

        expect(uri, isNotNull);
        expect(uri!.path, '/Audio/t1/stream');
      });

      test('a 404 maps to "stream unavailable" (track moved/removed)',
          () async {
        final source = _source(FakeJellyfinClient(
          streamProbe: const JellyfinStreamProbe(statusCode: 404),
        ));

        await expectLater(
          source.resolvePlayableUri(track),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.streamUnavailable,
          )),
        );
      });

      test('a 5xx maps to a server error', () async {
        final source = _source(FakeJellyfinClient(
          streamProbe: const JellyfinStreamProbe(statusCode: 503),
        ));

        await expectLater(
          source.resolvePlayableUri(track),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.serverError,
          )),
        );
      });

      test('an unclassifiable non-2xx maps to "unsupported response"',
          () async {
        final source = _source(FakeJellyfinClient(
          streamProbe: const JellyfinStreamProbe(statusCode: 400),
        ));

        await expectLater(
          source.resolvePlayableUri(track),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.unsupportedResponse,
          )),
        );
      });

      test('a transport failure during the probe propagates', () async {
        final source = _source(FakeJellyfinClient(
          probeError: JellyfinException.notReachable(),
        ));

        await expectLater(
          source.resolvePlayableUri(track),
          throwsA(isA<JellyfinException>().having(
            (JellyfinException e) => e.kind,
            'kind',
            JellyfinErrorKind.notReachable,
          )),
        );
      });
    });

    test('resolveDownloadUri mints a download URL with the token on demand',
        () async {
      final source = _source(FakeJellyfinClient());
      const track = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

      final uri = await source.resolveDownloadUri(track);

      expect(uri, isNotNull);
      expect(uri!.path, '/Items/t1/Download');
      expect(uri.host, 'music.example.com');
      expect(uri.queryParameters['api_key'], 'secret-token');
      // The track's own uri stays the token-free jellyfin id.
      expect(track.uri, 'jellyfin:t1');
    });

    test('verifyReachable delegates the check to the client', () async {
      final client = FakeJellyfinClient();

      await _source(client).verifyReachable();

      expect(client.verifyCount, 1);
    });

    test('verifyReachable surfaces a client failure', () async {
      final client = FakeJellyfinClient(
        verifyError: JellyfinException.unauthorized(),
      );

      await expectLater(
        _source(client).verifyReachable(),
        throwsA(isA<JellyfinException>()),
      );
    });
  });
}
