import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_music_source.dart';

import 'fake_plex_client.dart';

const String _token = 'tok-secret-123';

const PlexSession _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: _token,
  machineIdentifier: 'machine-abc',
  serverName: 'Living Room',
  selectedSectionKeys: <String>['3'],
);

const Track _track = Track(id: '301', title: 'Nightcall', uri: 'plex:301');

void main() {
  group('PlexMusicSource.resolveDownloadUri', () {
    late FakePlexClient client;
    late PlexMusicSource source;

    setUp(() {
      client = FakePlexClient();
      source = PlexMusicSource(session: _session, client: client);
    });

    test('looks up metadata and mints a tokenized original-file URL', () async {
      client.metadataByRatingKey = const <String, PlexMetadata>{
        '301': PlexMetadata(
          ratingKey: '301',
          type: 'track',
          title: 'Nightcall',
          media: <PlexMedia>[
            PlexMedia(parts: <PlexPart>[
              PlexPart(key: '/library/parts/9001/1700000000/file.flac'),
            ]),
          ],
        ),
      };

      final Uri? uri = await source.resolveDownloadUri(_track);

      expect(client.requestedRatingKeys, <String>['301']);
      expect(uri, isNotNull);
      expect(uri!.path, '/library/parts/9001/1700000000/file.flac');
      expect(uri.queryParameters['X-Plex-Token'], _token);
      expect(_track.uri, 'plex:301');
      expect(_track.uri, isNot(contains(_token)));
    });

    test('returns null when the item has no playable part', () async {
      client.metadataByRatingKey = const <String, PlexMetadata>{
        '301': PlexMetadata(ratingKey: '301', type: 'track', title: 'x'),
      };

      expect(await source.resolveDownloadUri(_track), isNull);
    });

    test('a vanished item surfaces as a typed, token-free PlexException', () {
      expect(
        () => source.resolveDownloadUri(_track),
        throwsA(
          isA<PlexException>()
              .having((e) => e.kind, 'kind', PlexErrorKind.notFound)
              .having((e) => e.message, 'message', isNot(contains(_token)))
              .having((e) => e.toString(), 'toString', isNot(contains(_token))),
        ),
      );
    });

    test('a Part key that is not server-absolute fails typed', () async {
      client.metadataByRatingKey = const <String, PlexMetadata>{
        '301': PlexMetadata(
          ratingKey: '301',
          type: 'track',
          title: 'x',
          media: <PlexMedia>[
            PlexMedia(parts: <PlexPart>[PlexPart(key: 'file.flac')]),
          ],
        ),
      };

      await expectLater(
        source.resolveDownloadUri(_track),
        throwsA(
          isA<PlexException>()
              .having((e) => e.kind, 'kind', PlexErrorKind.unsupportedResponse)
              .having((e) => e.message, 'message', isNot(contains(_token))),
        ),
      );
    });

    test('a uri with no ratingKey fails typed without issuing a junk request',
        () async {
      const Track malformed = Track(id: '', title: 'x', uri: 'plex:');

      await expectLater(
        source.resolveDownloadUri(malformed),
        throwsA(
          isA<PlexException>()
              .having((e) => e.kind, 'kind', PlexErrorKind.notFound)
              .having((e) => e.message, 'message', isNot(contains(_token))),
        ),
      );
      expect(client.requestedRatingKeys, isEmpty);
    });
  });
}
