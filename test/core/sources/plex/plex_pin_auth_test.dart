import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_pin_auth.dart';
import 'package:linthra/core/sources/plex/plex_tv_api.dart';

import 'fake_plex_client.dart';
import 'fake_plex_tv_client.dart';

const String _accountToken = 'super-secret-account-token';
const String _serverToken = 'super-secret-server-token';

const PlexClientIdentity _identity = PlexClientIdentity(
  clientIdentifier: 'install-uuid-1',
  product: 'Linthra',
  version: '0.1.5',
  platform: 'Android',
  device: 'Pixel',
);

const PlexResourceConnection _directConnection = PlexResourceConnection(
  uri: 'https://10-0-0-5.abc.plex.direct:32400',
  local: true,
);
const PlexResourceConnection _remoteConnection = PlexResourceConnection(
  uri: 'https://93-184-216-34.abc.plex.direct:32400',
);
const PlexResourceConnection _relayConnection = PlexResourceConnection(
  uri: 'https://relay.plex.direct:8443',
  relay: true,
);

const PlexResource _server = PlexResource(
  name: 'Office Server',
  clientIdentifier: 'machine-abc',
  provides: 'server',
  accessToken: _serverToken,
  productVersion: '1.41.0',
  connections: <PlexResourceConnection>[_directConnection, _remoteConnection],
);

PlexPinAuth _auth({
  FakePlexTvClient? tvClient,
  FakePlexClient? serverClient,
  List<Duration>? waits,
}) {
  return PlexPinAuth(
    tvClient: tvClient ?? FakePlexTvClient(),
    // The default server answers as `_server`'s machine, so a probe matches
    // the picked resource's clientIdentifier (the identity guard).
    serverClient: serverClient ??
        FakePlexClient(
          identity: const PlexServerIdentity(machineIdentifier: 'machine-abc'),
        ),
    identity: _identity,
    wait: (Duration duration) async => waits?.add(duration),
  );
}

void main() {
  group('begin', () {
    test('mints a pin and builds the browser page for it', () async {
      final tvClient = FakePlexTvClient(
        pin: const PlexPin(id: 99, code: 'the-code'),
      );
      final PlexPinAuth auth = _auth(tvClient: tvClient);

      final PlexPinLink link = await auth.begin();

      expect(link.pinId, 99);
      // The page is bound to the same client identifier the client's headers
      // announce — plex.tv ties the PIN to it.
      expect(
        link.authUrl.toString(),
        'https://app.plex.tv/auth#?clientID=install-uuid-1&code=the-code'
        '&context%5Bdevice%5D%5Bproduct%5D=Linthra',
      );
    });

    test('toString of the link never includes the code', () async {
      final PlexPinAuth auth = _auth(
        tvClient: FakePlexTvClient(
          pin: const PlexPin(id: 5, code: 'secretish-code'),
        ),
      );

      final PlexPinLink link = await auth.begin();

      expect(link.toString(), isNot(contains('secretish-code')));
    });
  });

  group('waitForAuthToken', () {
    test('polls until the token is granted, pacing with the interval',
        () async {
      final tvClient = FakePlexTvClient(
        checkPinScript: <Object?>[null, null, _accountToken],
      );
      final waits = <Duration>[];
      final PlexPinAuth auth = _auth(tvClient: tvClient, waits: waits);

      final String? token = await auth.waitForAuthToken(7);

      expect(token, _accountToken);
      expect(tvClient.checkPinCount, 3);
      expect(tvClient.lastCheckedPinId, 7);
      // Two pending polls → two waits, none after the grant.
      expect(waits, hasLength(2));
      expect(waits.toSet().single, PlexPinAuth.pollInterval);
    });

    test('returns null promptly once cancelled', () async {
      int polls = 0;
      final tvClient = FakePlexTvClient();
      final PlexPinAuth auth = PlexPinAuth(
        tvClient: tvClient,
        serverClient: FakePlexClient(),
        identity: _identity,
        wait: (_) async => polls++,
      );

      final String? token = await auth.waitForAuthToken(
        7,
        // Cancel after the second pending answer.
        isCancelled: () => tvClient.checkPinCount >= 2,
      );

      expect(token, isNull);
      expect(tvClient.checkPinCount, 2);
    });

    test('an expired pin (404) propagates as sign-in expired', () async {
      final tvClient = FakePlexTvClient(
        checkPinScript: <Object?>[null, PlexException.signInExpired()],
      );
      final PlexPinAuth auth = _auth(tvClient: tvClient);

      await expectLater(
        auth.waitForAuthToken(7),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unauthorized)),
      );
    });

    test('tolerates transient failures while the user is away in the browser',
        () async {
      final tvClient = FakePlexTvClient(
        checkPinScript: <Object?>[
          null,
          PlexException.plexTvUnreachable(),
          PlexException.plexTvError(503),
          null,
          _accountToken,
        ],
      );
      final PlexPinAuth auth = _auth(tvClient: tvClient);

      expect(await auth.waitForAuthToken(7), _accountToken);
    });

    test('gives up after too many consecutive failures', () async {
      final tvClient = FakePlexTvClient(
        checkPinScript: <Object?>[
          for (int i = 0; i < PlexPinAuth.maxConsecutivePollFailures; i++)
            PlexException.plexTvUnreachable(),
        ],
      );
      final PlexPinAuth auth = _auth(tvClient: tvClient);

      await expectLater(
        auth.waitForAuthToken(7),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notReachable)),
      );
      expect(
        tvClient.checkPinCount,
        PlexPinAuth.maxConsecutivePollFailures,
      );
    });

    test('a poll that never gets approved expires at the timeout', () async {
      // An empty script answers "pending" forever; the instant wait lets the
      // loop burn through the whole timeout's worth of attempts.
      final tvClient = FakePlexTvClient();
      final PlexPinAuth auth = _auth(tvClient: tvClient);

      await expectLater(
        auth.waitForAuthToken(7),
        throwsA(isA<PlexException>()
            .having((e) => e.message, 'message', contains('expired'))),
      );
    });
  });

  group('fetchServers', () {
    test('keeps only resources that provide server, owned first', () async {
      const PlexResource shared = PlexResource(
        name: 'Shared box',
        clientIdentifier: 'machine-shared',
        provides: 'server',
        owned: false,
      );
      const PlexResource player = PlexResource(
        name: 'Some player',
        clientIdentifier: 'machine-player',
        provides: 'client,player',
      );
      final tvClient = FakePlexTvClient(
        resources: const <PlexResource>[shared, player, _server],
      );
      final PlexPinAuth auth = _auth(tvClient: tvClient);

      final List<PlexResource> servers =
          await auth.fetchServers(accountToken: _accountToken);

      expect(servers.map((r) => r.clientIdentifier),
          <String>['machine-abc', 'machine-shared']);
      expect(tvClient.lastResourcesToken, _accountToken);
    });
  });

  group('connectToServer', () {
    test('prefers the server-scoped token and probes the first connection',
        () async {
      final serverClient = FakePlexClient(
        identity: const PlexServerIdentity(
          machineIdentifier: 'machine-abc',
          version: '1.41.0.9999',
        ),
      );
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      final PlexSession session = await auth.connectToServer(
        server: _server,
        accountToken: _accountToken,
      );

      // The narrowest credential that works: the per-server accessToken, not
      // the account-wide token.
      expect(session.token, _serverToken);
      expect(serverClient.lastToken, _serverToken);
      expect(session.baseUrl, 'https://10-0-0-5.abc.plex.direct:32400');
      expect(session.machineIdentifier, 'machine-abc');
      expect(session.serverName, 'Office Server');
      expect(session.serverVersion, '1.41.0.9999');
      // The library picker starts empty — selection is the user's next step.
      expect(session.selectedSectionKeys, isEmpty);
    });

    test('falls back to the account token when no scoped token exists',
        () async {
      const PlexResource unscoped = PlexResource(
        name: 'S',
        clientIdentifier: 'machine-abc',
        provides: 'server',
        connections: <PlexResourceConnection>[_directConnection],
      );
      final serverClient = FakePlexClient(
        identity: const PlexServerIdentity(machineIdentifier: 'machine-abc'),
      );
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      final PlexSession session = await auth.connectToServer(
        server: unscoped,
        accountToken: _accountToken,
      );

      expect(session.token, _accountToken);
    });

    test('skips an address that answers as a different server', () async {
      // The first advertised address is stale and now reaches a DIFFERENT
      // server that still accepts the account-wide token; the second reaches
      // the real one. Only the server the user picked is persisted.
      final probed = <String>[];
      final serverClient = _IdentityByUrlClient(
        probed,
        identityFor: const <String, PlexServerIdentity>{
          'https://10-0-0-5.abc.plex.direct:32400':
              PlexServerIdentity(machineIdentifier: 'someone-elses-server'),
          'https://93-184-216-34.abc.plex.direct:32400':
              PlexServerIdentity(machineIdentifier: 'machine-abc'),
        },
      );
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      final PlexSession session = await auth.connectToServer(
        server: _server,
        accountToken: _accountToken,
      );

      // Both addresses were probed; the matching one won.
      expect(probed, <String>[
        'https://10-0-0-5.abc.plex.direct:32400',
        'https://93-184-216-34.abc.plex.direct:32400',
      ]);
      expect(session.machineIdentifier, 'machine-abc');
      expect(session.baseUrl, 'https://93-184-216-34.abc.plex.direct:32400');
    });

    test('reports unreachable when no address reaches the picked server',
        () async {
      // Every advertised address answers as a different server — none is the
      // one the user picked, so nothing is persisted.
      final serverClient = FakePlexClient(
        identity:
            const PlexServerIdentity(machineIdentifier: 'not-the-picked-one'),
      );
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      await expectLater(
        auth.connectToServer(server: _server, accountToken: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notReachable)),
      );
    });

    test('keeps the relay as the last resort', () async {
      final probed = <String>[];
      final serverClient = _ProbeRecordingClient(
        probed,
        failFor: <String>{
          // Both direct addresses are unreachable; only the relay answers.
          'https://10-0-0-5.abc.plex.direct:32400',
          'https://93-184-216-34.abc.plex.direct:32400',
        },
      );
      const PlexResource server = PlexResource(
        name: 'S',
        clientIdentifier: 'machine-abc',
        provides: 'server',
        accessToken: _serverToken,
        // plex.tv put the relay first; the probe order must still demote it.
        connections: <PlexResourceConnection>[
          _relayConnection,
          _directConnection,
          _remoteConnection,
        ],
      );
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      final PlexSession session = await auth.connectToServer(
        server: server,
        accountToken: _accountToken,
      );

      expect(probed, <String>[
        'https://10-0-0-5.abc.plex.direct:32400',
        'https://93-184-216-34.abc.plex.direct:32400',
        'https://relay.plex.direct:8443',
      ]);
      expect(session.baseUrl, 'https://relay.plex.direct:8443');
    });

    test('a rejected token aborts immediately instead of probing on', () async {
      final probed = <String>[];
      final serverClient = _ProbeRecordingClient(
        probed,
        errorFor: <String, PlexException>{
          'https://10-0-0-5.abc.plex.direct:32400':
              PlexException.unauthorized(),
        },
      );
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      await expectLater(
        auth.connectToServer(server: _server, accountToken: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unauthorized)),
      );
      // The same token would be rejected on every address — one probe only.
      expect(probed, hasLength(1));
    });

    test('reports unreachable when no address answers', () async {
      final serverClient =
          FakePlexClient(identityError: PlexException.notReachable());
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      await expectLater(
        auth.connectToServer(server: _server, accountToken: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notReachable)
            .having((e) => e.message, 'message', contains('addresses'))),
      );
    });

    test('reports unreachable for a server with no usable address', () async {
      const PlexResource server = PlexResource(
        name: 'S',
        clientIdentifier: 'machine-abc',
        provides: 'server',
        connections: <PlexResourceConnection>[
          PlexResourceConnection(uri: 'ftp://not-a-web-address'),
        ],
      );
      final PlexPinAuth auth = _auth();

      await expectLater(
        auth.connectToServer(server: server, accountToken: _accountToken),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notReachable)),
      );
    });

    test('the produced session keeps redacting its token', () async {
      final PlexPinAuth auth = _auth();

      final PlexSession session = await auth.connectToServer(
        server: _server,
        accountToken: _accountToken,
      );

      final String text = session.toString();
      expect(text, isNot(contains(_serverToken)));
      expect(text, isNot(contains(_accountToken)));
      expect(text, contains('<redacted>'));
    });

    test('failure messages never carry either token', () async {
      final serverClient =
          FakePlexClient(identityError: PlexException.notReachable());
      final PlexPinAuth auth = _auth(serverClient: serverClient);

      try {
        await auth.connectToServer(
          server: _server,
          accountToken: _accountToken,
        );
        fail('expected a PlexException');
      } on PlexException catch (error) {
        expect(error.message, isNot(contains(_serverToken)));
        expect(error.message, isNot(contains(_accountToken)));
      }
    });
  });
}

/// A [FakePlexClient] that records the probed base URLs and can fail
/// specific ones, so the connection-order logic can be asserted.
class _ProbeRecordingClient extends FakePlexClient {
  _ProbeRecordingClient(
    this.probed, {
    this.failFor = const <String>{},
    this.errorFor = const <String, PlexException>{},
  });

  final List<String> probed;
  final Set<String> failFor;
  final Map<String, PlexException> errorFor;

  @override
  Future<PlexServerIdentity> fetchIdentity({
    required String baseUrl,
    required String token,
  }) async {
    probed.add(baseUrl);
    final PlexException? specific = errorFor[baseUrl];
    if (specific != null) throw specific;
    if (failFor.contains(baseUrl)) throw PlexException.notReachable();
    return const PlexServerIdentity(machineIdentifier: 'machine-abc');
  }
}

/// A [FakePlexClient] that records probed base URLs and returns a per-URL
/// identity, so the "address answers as a different server" guard can be
/// exercised. An unmapped URL is treated as unreachable.
class _IdentityByUrlClient extends FakePlexClient {
  _IdentityByUrlClient(this.probed, {required this.identityFor});

  final List<String> probed;
  final Map<String, PlexServerIdentity> identityFor;

  @override
  Future<PlexServerIdentity> fetchIdentity({
    required String baseUrl,
    required String token,
  }) async {
    probed.add(baseUrl);
    final PlexServerIdentity? id = identityFor[baseUrl];
    if (id == null) throw PlexException.notReachable();
    return id;
  }
}
