// A request that times out reads as "can't reach the server", for every
// remote provider.
//
// Each HTTP client puts a timeout on its requests, and the sync and the
// player branch on the typed failure that comes out: "not reachable" keeps
// the library and offers a retry, while a server error, an auth failure or
// "not a Jellyfin/Subsonic/Plex server" each say something else to the user.
// A TimeoutException from the transport has to come out as notReachable,
// never raw. Jellyfin's library pages retry a timeout like any other
// transport failure, within the same attempt budget.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';

/// A transport that times out on every request, counting them.
class _TimingOut {
  int requests = 0;

  late final MockClient client = MockClient((http.Request request) async {
    requests++;
    throw TimeoutException('no answer', const Duration(seconds: 20));
  });
}

void main() {
  group('Jellyfin', () {
    const JellyfinSession session = JellyfinSession(
      baseUrl: 'https://music.example.com',
      userId: 'user-1',
      accessToken: 'tok',
      deviceId: 'device-1',
    );

    test('a single request that times out is notReachable, sent once',
        () async {
      final _TimingOut transport = _TimingOut();
      final HttpJellyfinClient client =
          HttpJellyfinClient(httpClient: transport.client);

      await expectLater(
        client.verifySession(session),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notReachable,
        )),
      );
      expect(transport.requests, 1);
    });

    test(
        'a library page that keeps timing out is tried the whole attempt '
        'budget, then is notReachable', () async {
      final _TimingOut transport = _TimingOut();
      final HttpJellyfinClient client = HttpJellyfinClient(
        httpClient: transport.client,
        maxItemFetchAttempts: 3,
        retryBackoff: Duration.zero,
        pageGap: Duration.zero,
      );

      await expectLater(
        client.fetchItems(session, kind: JellyfinItemKind.audio),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.notReachable,
        )),
      );
      expect(transport.requests, 3);
    });
  });

  test('Subsonic: a request that times out is notReachable', () async {
    final _TimingOut transport = _TimingOut();
    final HttpSubsonicClient client =
        HttpSubsonicClient(httpClient: transport.client);

    await expectLater(
      client.verifySession(const SubsonicSession(
        baseUrl: 'https://music.example.com',
        username: 'alice',
        salt: 'salt1',
        token: 'secret-token',
      )),
      throwsA(isA<SubsonicException>().having(
        (SubsonicException e) => e.kind,
        'kind',
        SubsonicErrorKind.notReachable,
      )),
    );
    expect(transport.requests, 1);
  });

  group('Plex', () {
    HttpPlexClient plexClient(MockClient transport) => HttpPlexClient(
          identity: const PlexClientIdentity(
            clientIdentifier: 'install-1',
            product: 'Linthra',
            version: '0.0.0',
            platform: 'Linux',
            device: 'Test',
          ),
          httpClient: transport,
        );

    test('a request that times out is notReachable', () async {
      final _TimingOut transport = _TimingOut();

      await expectLater(
        plexClient(transport.client).fetchIdentity(
          baseUrl: 'https://plex.example.com:32400',
          token: 'tok',
        ),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notReachable,
        )),
      );
      expect(transport.requests, 1);
    });

    test('a section page that times out is notReachable, not retried',
        () async {
      final _TimingOut transport = _TimingOut();

      await expectLater(
        plexClient(transport.client).fetchSectionItems(
          baseUrl: 'https://plex.example.com:32400',
          token: 'tok',
          sectionKey: '3',
          itemType: PlexMetadataType.track,
        ),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.notReachable,
        )),
      );
      expect(transport.requests, 1);
    });
  });
}
