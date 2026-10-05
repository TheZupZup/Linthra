import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/subsonic/subsonic_catalog_walk.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';

import 'synthetic_navidrome.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'secret-token',
);

/// The production retry count, without the waits.
const List<Duration> _noWait = <Duration>[Duration.zero, Duration.zero];

/// Walks [server]'s library, collecting every batch handed out.
Future<(SubsonicCatalogWalk, List<List<Track>>)> _walk(
  SyntheticNavidrome server, {
  int batchSize = 100,
  int maxAlbumPages = SubsonicMusicSource.maxAlbumPages,
  bool Function(int batchIndex)? keepGoing,
}) async {
  final List<List<Track>> batches = <List<Track>>[];
  final SubsonicCatalogWalk walk = await SubsonicMusicSource(
    session: _session,
    client: server.client(),
  ).walkTracks(
    batchSize: batchSize,
    retryDelays: _noWait,
    maxAlbumPages: maxAlbumPages,
    onBatch: (List<Track> batch) async {
      batches.add(List<Track>.of(batch));
      return keepGoing?.call(batches.length - 1) ?? true;
    },
  );
  return (walk, batches);
}

/// Set equality in linear time. `expect(a, b)` on two sets deep-matches every
/// element against every other, which is quadratic and takes minutes at 80k.
void _expectSameSet(Set<String> actual, Set<String> expected) {
  expect(actual.length, expected.length);
  expect(expected.difference(actual), isEmpty);
}

Set<String> _uris(List<List<Track>> batches) => <String>{
      for (final List<Track> batch in batches)
        for (final Track track in batch) track.uri,
    };

void main() {
  group('SubsonicMusicSource.walkTracks', () {
    test('hands a large library out in bounded batches', () async {
      // 3,000 albums x 10 = 30,000 tracks.
      final SyntheticNavidrome server = SyntheticNavidrome(albums: 3000);

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server, batchSize: 2000);

      expect(walk.isComplete, isTrue);
      expect(walk.albumCount, 3000);
      expect(walk.trackCount, 30000);
      _expectSameSet(_uris(batches), server.urisFor('alice'));
      // Every batch but the last is between batchSize and one album over it.
      for (final List<Track> batch in batches.take(batches.length - 1)) {
        expect(batch.length, inInclusiveRange(2000, 2000 + 10));
      }
      expect(batches.last.length, lessThanOrEqualTo(2000 + 10));
      // Six full pages plus the empty one that ends the list, read twice (the
      // second time to catch an album that moved during the first, #752), and
      // one getAlbum per album. No artist pass.
      expect(server.albumListCalls, 2 * 7);
      expect(server.albumCalls, 3000);
      expect(server.calls.containsKey('getArtists'), isFalse);
    });

    test('a list that exactly fills its pages still ends and is complete',
        () async {
      final SyntheticNavidrome server = SyntheticNavidrome(albums: 1000);

      final (SubsonicCatalogWalk walk, _) = await _walk(server);

      // 500, 500, then an empty page; twice.
      expect(server.albumListCalls, 2 * 3);
      expect(walk.truncated, isFalse);
      expect(walk.isComplete, isTrue);
    });

    test('hitting the album page cap is reported as truncated', () async {
      // 1,200 albums but room for only two pages of 500.
      final SyntheticNavidrome server = SyntheticNavidrome(albums: 1200);

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server, maxAlbumPages: 2);

      expect(walk.truncated, isTrue);
      expect(walk.isComplete, isFalse);
      // What it did read is still handed out.
      expect(walk.albumCount, 1000);
      expect(_uris(batches).length, 10000);
    });

    test('a server that ignores offset hits the cap, each album read once',
        () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 600, ignoreOffset: true);

      final (SubsonicCatalogWalk walk, _) = await _walk(server);

      expect(server.albumListCalls, SubsonicMusicSource.maxAlbumPages);
      expect(walk.truncated, isTrue);
      expect(walk.isComplete, isFalse);
      // The repeated first page is de-duplicated by album id.
      expect(walk.albumCount, 500);
      expect(server.albumCalls, 500);
    });

    test('an album removed mid-walk (error 70) is skipped, walk complete',
        () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 50, missingAlbums: <int>{3});

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server);

      expect(walk.missingAlbumCount, 1);
      expect(walk.isComplete, isTrue);
      _expectSameSet(
          _uris(batches), server.urisFor('alice', exceptAlbums: <int>{3}));
      // Not found is final: no retry.
      expect(server.albumCalls, 50);
    });

    test('too many missing albums makes the walk untrustworthy for pruning',
        () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 10, missingAlbums: <int>{1, 2});

      final (SubsonicCatalogWalk walk, _) = await _walk(server);

      expect(walk.missingAlbumCount, 2);
      expect(walk.truncated, isFalse);
      expect(walk.isComplete, isFalse);
    });

    test('transient failures are retried and the walk completes', () async {
      final SyntheticNavidrome server = SyntheticNavidrome(
        albums: 40,
        failingAlbumCalls: <int>{3, 20},
        serverErrorAlbumCalls: <int>{10},
      );

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server);

      expect(walk.isComplete, isTrue);
      _expectSameSet(_uris(batches), server.urisFor('alice'));
      expect(server.albumCalls, 40 + 3);
    });

    test(
        'a persistent failure propagates after the retries, earlier batches '
        'already delivered', () async {
      // The network goes away at the 30th album.
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 100, failAlbumCallsFrom: 30);
      final List<List<Track>> batches = <List<Track>>[];

      await expectLater(
        SubsonicMusicSource(session: _session, client: server.client())
            .walkTracks(
          batchSize: 50,
          retryDelays: _noWait,
          onBatch: (List<Track> batch) async {
            batches.add(List<Track>.of(batch));
            return true;
          },
        ),
        throwsA(isA<SubsonicException>().having(
          (SubsonicException e) => e.kind,
          'kind',
          SubsonicErrorKind.notReachable,
        )),
      );
      // 29 albums read: five full batches of 50 went out, the partial one
      // (40 tracks) was still being filled.
      expect(_uris(batches).length, 250);
      // The failing call plus its two retries, then a ping (and its retries)
      // that found the server gone too, so it isn't one album's fault.
      expect(server.albumCalls, 29 + 3);
      expect(server.calls['ping'], 3);
    });

    test('a rate-limited request (HTTP 429) is retried', () async {
      final SyntheticNavidrome server = SyntheticNavidrome(
        albums: 20,
        rateLimitedAlbumCalls: <int>{5, 12},
      );

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server);

      expect(walk.isComplete, isTrue);
      _expectSameSet(_uris(batches), server.urisFor('alice'));
      expect(server.albumCalls, 20 + 2);
    });

    test('a rejected credential is not retried', () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 10, rejectCredentialsFromAlbumCall: 4);

      await expectLater(
        _walk(server),
        throwsA(isA<SubsonicException>().having(
          (SubsonicException e) => e.kind,
          'kind',
          SubsonicErrorKind.unauthorized,
        )),
      );
      expect(server.albumCalls, 4);
    });

    test(
        'an album that always fails is left out and the walk goes on, '
        'not complete (#740)', () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 50, brokenAlbums: <int>{25});

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server);

      expect(walk.failedAlbumCount, 1);
      expect(walk.isComplete, isFalse);
      // It would only fail the same way on every resume.
      expect(walk.worthResuming, isFalse);
      _expectSameSet(
          _uris(batches), server.urisFor('alice', exceptAlbums: <int>{25}));
      // The broken album with its two retries, and one ping to make sure the
      // server itself still answers.
      expect(server.albumCalls, 50 + 2);
      expect(server.calls['ping'], 1);
    });

    test('once three albums have failed, the rest get one attempt each',
        () async {
      final SyntheticNavidrome server = SyntheticNavidrome(
        albums: 50,
        brokenAlbums: <int>{1, 2, 3, 4, 5},
      );

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server);

      expect(walk.failedAlbumCount, 5);
      expect(
        _uris(batches),
        hasLength(server.urisFor('alice').length - 5 * 10),
      );
      expect(server.albumCalls, 50 + 3 * 2);
    });

    test(
        'an album deleted between two pages shifts the next one back; the '
        'second reading walks it (#752)', () async {
      // Album 10 goes after the first page is listed, so album 500 moves into
      // that first page and the second page starts at 501.
      final SyntheticNavidrome server = SyntheticNavidrome(
        albums: 1000,
        afterAlbumListCall: (SyntheticNavidrome server, int call) {
          if (call == 1) server.removeFromListing(10);
        },
      );

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server, batchSize: 2000);

      expect(walk.isComplete, isTrue);
      expect(walk.missingAlbumCount, 1);
      expect(walk.albumCount, 1000);
      _expectSameSet(
          _uris(batches), server.urisFor('alice', exceptAlbums: <int>{10}));
    });

    test('an album renamed to sort first between two pages is walked (#752)',
        () async {
      final SyntheticNavidrome server = SyntheticNavidrome(
        albums: 1000,
        afterAlbumListCall: (SyntheticNavidrome server, int call) {
          if (call == 1) server.moveToFrontOfListing(900);
        },
      );

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server, batchSize: 2000);

      expect(walk.isComplete, isTrue);
      _expectSameSet(_uris(batches), server.urisFor('alice'));
      // Album 499 shifted into the second page as well, and is read once.
      expect(server.albumCalls, 1000);
    });

    test('a second reading that fails keeps what was read, unconfirmed',
        () async {
      // 1,000 albums: the first reading takes three list calls.
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 1000, failAlbumListCallsFrom: 4);

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server, batchSize: 2000);

      expect(walk.listingConfirmed, isFalse);
      expect(walk.isComplete, isFalse);
      // Reading it again at the next resume can confirm it.
      expect(walk.worthResuming, isTrue);
      _expectSameSet(_uris(batches), server.urisFor('alice'));
    });

    test('onBatch returning false stops the walk', () async {
      final SyntheticNavidrome server = SyntheticNavidrome(albums: 100);

      final (SubsonicCatalogWalk walk, List<List<Track>> batches) =
          await _walk(server, batchSize: 50, keepGoing: (_) => false);

      expect(walk.stopped, isTrue);
      expect(walk.isComplete, isFalse);
      expect(batches, hasLength(1));
      expect(server.albumCalls, 5);
    });
  });
}
