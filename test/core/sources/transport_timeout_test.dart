// A request that times out reads as "can't reach the server", and a library
// page that times out is retried like any other transport failure.
//
// The sync and the player branch on the typed failure that comes out: "not
// reachable" keeps the library and offers a retry, while a server error, an
// auth failure or "not a Subsonic server" each say something else to the
// user. Subsonic sorts transport errors by their text (a blocked cleartext
// request, a failed TLS handshake, an unreachable host), and a timeout has to
// keep coming out as unreachable rather than as one of the others. Jellyfin's
// library pages must spend their whole attempt budget on a timeout, as on any
// dropped connection, before giving up.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
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
  test(
      'Jellyfin: a library page that keeps timing out is tried the whole '
      'attempt budget, then is notReachable', () async {
    final _TimingOut transport = _TimingOut();
    final HttpJellyfinClient client = HttpJellyfinClient(
      httpClient: transport.client,
      maxItemFetchAttempts: 3,
      retryBackoff: Duration.zero,
      pageGap: Duration.zero,
    );

    await expectLater(
      client.fetchItems(
        const JellyfinSession(
          baseUrl: 'https://music.example.com',
          userId: 'user-1',
          accessToken: 'tok',
          deviceId: 'device-1',
        ),
        kind: JellyfinItemKind.audio,
      ),
      throwsA(isA<JellyfinException>().having(
        (JellyfinException e) => e.kind,
        'kind',
        JellyfinErrorKind.notReachable,
      )),
    );
    expect(transport.requests, 3);
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
}
