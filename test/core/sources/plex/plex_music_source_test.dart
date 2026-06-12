import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_diagnostics.dart';
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
  selectedSectionKeys: <String>['3', '7'],
);

/// The same sign-in before the library picker has run: no sections selected.
const PlexSession _noSelectionSession = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: _token,
  machineIdentifier: 'machine-abc',
);

void main() {
  late FakePlexClient client;

  PlexMusicSource source({PlexSession session = _session}) =>
      PlexMusicSource(session: session, client: client);

  setUp(() => client = FakePlexClient());

  group('identity', () {
    test('id is the stable "plex"', () {
      expect(source().id, 'plex');
      expect(PlexMusicSource.sourceId, 'plex');
    });

    test('displayName names the server when known, else plain Plex', () {
      expect(source().displayName, 'Plex · Living Room');
      // The manual /identity flow learns no server name.
      expect(source(session: _noSelectionSession).displayName, 'Plex');
    });
  });

  group('fetchArtists', () {
    test('lists Plex type 8 from every selected section, in order', () async {
      client.itemsByType = const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.artist: <PlexMetadata>[
          PlexMetadata(ratingKey: '101', type: 'artist', title: 'Kavinsky'),
        ],
      };

      final artists = await source().fetchArtists();

      expect(
          client.itemRequests,
          <({String sectionKey, PlexMetadataType itemType})>[
            (sectionKey: '3', itemType: PlexMetadataType.artist),
            (sectionKey: '7', itemType: PlexMetadataType.artist),
          ]);
      expect(client.itemRequests.first.itemType.value, 8);
      // One canned artist per section → the results are concatenated.
      expect(artists, hasLength(2));
      expect(artists.first.name, 'Kavinsky');
      // The session's address and token went to the client (header-side).
      expect(client.lastBaseUrl, _session.baseUrl);
      expect(client.lastToken, _token);
    });
  });

  group('fetchAlbums', () {
    test('lists Plex type 9 from every selected section', () async {
      client.itemsByType = const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.album: <PlexMetadata>[
          PlexMetadata(
            ratingKey: '201',
            type: 'album',
            title: 'OutRun',
            parentTitle: 'Kavinsky',
          ),
        ],
      };

      final albums = await source().fetchAlbums();

      expect(
        client.itemRequests.map((r) => r.sectionKey),
        <String>['3', '7'],
      );
      expect(client.itemRequests.first.itemType, PlexMetadataType.album);
      expect(client.itemRequests.first.itemType.value, 9);
      expect(albums, hasLength(2));
      expect(albums.first.title, 'OutRun');
      expect(albums.first.artistName, 'Kavinsky');
    });
  });

  group('fetchTracks', () {
    test('lists Plex type 10 from every selected section', () async {
      client.itemsByType = const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.track: <PlexMetadata>[
          PlexMetadata(
            ratingKey: '301',
            type: 'track',
            title: 'Nightcall',
            parentTitle: 'OutRun',
            grandparentTitle: 'Kavinsky',
            duration: 258000,
          ),
        ],
      };

      final tracks = await source().fetchTracks();

      expect(client.itemRequests.first.itemType, PlexMetadataType.track);
      expect(client.itemRequests.first.itemType.value, 10);
      expect(tracks, hasLength(2));
      expect(tracks.first.uri, 'plex:301');
      expect(tracks.first.artistName, 'Kavinsky');
    });

    test('never lets the token reach a mapped track or its artwork', () async {
      client.itemsByType = const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.track: <PlexMetadata>[
          PlexMetadata(
            ratingKey: '301',
            type: 'track',
            title: 'Nightcall',
            thumb: '/library/metadata/201/thumb/1700000000',
          ),
        ],
      };

      final tracks = await source().fetchTracks();

      expect(tracks, isNotEmpty);
      for (final Track t in tracks) {
        // The id is the bare ratingKey — no token, no server address.
        expect(t.id, '301');
        expect(t.id, isNot(contains(_token)));
        // The opaque plex: uri carries no token, no query, no server address.
        expect(t.uri, startsWith('plex:'));
        expect(t.uri, isNot(contains(_token)));
        expect(t.uri, isNot(contains('X-Plex-Token')));
        expect(t.uri, isNot(contains('plex.example.com')));
        // The artwork reference is equally credential-free.
        final String artwork = t.artworkUri.toString();
        expect(artwork, startsWith('plex-thumb:'));
        expect(artwork, isNot(contains(_token)));
        expect(artwork, isNot(contains('X-Plex-Token')));
        expect(artwork, isNot(contains('plex.example.com')));
      }
    });
  });

  group('library selection scoping', () {
    test('an empty selection yields empty lists without touching the server',
        () async {
      client.itemsByType = const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.artist: <PlexMetadata>[
          PlexMetadata(ratingKey: '101', type: 'artist', title: 'Kavinsky'),
        ],
      };
      final s = source(session: _noSelectionSession);

      expect(await s.fetchArtists(), isEmpty);
      expect(await s.fetchAlbums(), isEmpty);
      expect(await s.fetchTracks(), isEmpty);
      // No selection → no section listing was even attempted.
      expect(client.itemRequests, isEmpty);
    });
  });

  group('resolvePlayableUri', () {
    const Track track = Track(id: '301', title: 'Nightcall', uri: 'plex:301');

    test('looks up the metadata and mints the tokenized URL only then',
        () async {
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

      final uri = await source().resolvePlayableUri(track);

      // The play-time lookup used the ratingKey from the opaque uri.
      expect(client.requestedRatingKeys, <String>['301']);
      // The resolved URL streams the Part key — not the ratingKey — and the
      // token is woven into its query only now, at play time.
      expect(uri, isNotNull);
      expect(uri!.path, '/library/parts/9001/1700000000/file.flac');
      expect(uri.queryParameters['X-Plex-Token'], _token);
      // The track itself still carries the opaque, token-free reference.
      expect(track.uri, 'plex:301');
    });

    test('falls back to the track id for an unprefixed uri', () async {
      client.metadataByRatingKey = const <String, PlexMetadata>{
        '77': PlexMetadata(
          ratingKey: '77',
          type: 'track',
          title: 'x',
          media: <PlexMedia>[
            PlexMedia(parts: <PlexPart>[PlexPart(key: '/library/parts/1/f')]),
          ],
        ),
      };
      const Track unprefixed = Track(id: '77', title: 'x', uri: 'not-plex');

      final uri = await source().resolvePlayableUri(unprefixed);

      expect(client.requestedRatingKeys, <String>['77']);
      expect(uri, isNotNull);
    });

    test('returns null when the item carries no playable part', () async {
      client.metadataByRatingKey = const <String, PlexMetadata>{
        '301': PlexMetadata(ratingKey: '301', type: 'track', title: 'x'),
      };
      expect(await source().resolvePlayableUri(track), isNull);
    });

    test('a vanished item surfaces as a typed, token-free PlexException', () {
      // The fake (like the real client mapping a 404) throws notFound for an
      // unknown ratingKey.
      expect(
        () => source().resolvePlayableUri(track),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notFound)
            .having((e) => e.message, 'message', isNot(contains(_token)))
            .having((e) => e.toString(), 'toString', isNot(contains(_token)))),
      );
    });

    test('a uri with no ratingKey fails typed without issuing a junk request',
        () async {
      // A corrupt catalog row could carry a bare `plex:`; that names no item,
      // so it must fail as the same typed "not available" a vanished item
      // gets — and never reach the server as a malformed /library/metadata/
      // request.
      const Track malformed = Track(id: '', title: 'x', uri: 'plex:');
      await expectLater(
        source().resolvePlayableUri(malformed),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notFound)
            .having((e) => e.message, 'message', isNot(contains(_token)))),
      );
      expect(client.requestedRatingKeys, isEmpty);
    });

    test('a Part key that is not server-absolute fails typed, never corrupt',
        () async {
      // Joined as-is, `file.flac` would splice into the base URL's authority
      // (`…:32400file.flac` — an invalid port, or worse a different host).
      // The source must refuse it as the typed "response Linthra could not
      // use" instead of minting a corrupt URL or escaping as an untyped
      // FormatException the player can't word.
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
        source().resolvePlayableUri(track),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unsupportedResponse)
            .having((e) => e.message, 'message', isNot(contains(_token)))),
      );
    });

    test('the resolution diagnostic line redacts the id and holds no token',
        () async {
      // resolvePlayableUri logs exactly this line; the diagnostics API has no
      // parameter a token could even ride in, and the ratingKey is hashed —
      // a 9-digit key cannot survive into the ≤8-hex-char redacted tag.
      const String ratingKey = '987654321';
      final String line = PlaybackDiagnostics.describe(
        source: PlexMusicSource.sourceId,
        resolver: 'PlexMusicSource',
        itemId: ratingKey,
      );
      expect(line, contains('source=plex'));
      expect(line, contains('item=id#'));
      expect(line, isNot(contains(ratingKey)));
      expect(line, isNot(contains(_token)));
      expect(line.toLowerCase(), isNot(contains('x-plex-token')));
    });
  });

  test('verifyReachable checks the server identity with the session', () async {
    await source().verifyReachable();
    expect(client.identityCount, 1);
    expect(client.lastBaseUrl, _session.baseUrl);
    expect(client.lastToken, _token);
  });
}
