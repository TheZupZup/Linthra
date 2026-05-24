import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_authenticator.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';

import 'fake_jellyfin_client.dart';

JellyfinAuthenticator _authenticator(
  FakeJellyfinClient client, {
  String deviceId = 'device-fixed',
}) {
  return JellyfinAuthenticator(client, deviceIdGenerator: () => deviceId);
}

void main() {
  group('JellyfinAuthenticator.testConnection', () {
    test('normalizes the URL and returns server info', () async {
      final client = FakeJellyfinClient(
        serverInfo:
            const JellyfinServerInfo(serverName: 'Home', version: '10.9.0'),
      );

      final info =
          await _authenticator(client).testConnection('music.example.com');

      expect(info.serverName, 'Home');
      // Normalized: bare host got the https scheme.
      expect(client.lastBaseUrl, 'https://music.example.com');
    });

    test('throws on an invalid URL before touching the client', () async {
      final client = FakeJellyfinClient();

      await expectLater(
        _authenticator(client).testConnection('   '),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.invalidUrl,
        )),
      );
      expect(client.lastBaseUrl, isNull);
    });
  });

  group('JellyfinAuthenticator.signIn', () {
    test('builds a session from the auth result and a fresh device id',
        () async {
      final client = FakeJellyfinClient(
        authResult: const JellyfinAuthResult(
          accessToken: 'tok-123',
          userId: 'u-1',
          userName: 'Alice',
          serverId: 's-1',
        ),
      );

      final session = await _authenticator(client, deviceId: 'dev-9').signIn(
        rawUrl: 'music.example.com',
        username: 'alice',
        password: 'pw',
        serverInfo: const JellyfinServerInfo(
          serverName: 'Home',
          version: '10.9.0',
          productName: 'Jellyfin Server',
        ),
      );

      expect(session.baseUrl, 'https://music.example.com');
      expect(session.accessToken, 'tok-123');
      expect(session.userId, 'u-1');
      expect(session.userName, 'Alice');
      expect(session.serverId, 's-1');
      expect(session.deviceId, 'dev-9');
      // A known server info (from a prior test) is carried into the session for
      // display and diagnostics.
      expect(session.serverName, 'Home');
      expect(session.serverVersion, '10.9.0');
      expect(session.productName, 'Jellyfin Server');
      // The same device id was sent to the auth call.
      expect(client.lastDeviceId, 'dev-9');
    });

    test('reads server info itself when none was supplied', () async {
      // A user who signs in without tapping "Test connection" first: sign-in
      // reads /System/Info/Public so the session still records the version.
      final client = FakeJellyfinClient(
        serverInfo: const JellyfinServerInfo(
          serverName: 'Fetched',
          version: '10.10.3',
        ),
      );

      final session = await _authenticator(client).signIn(
        rawUrl: 'music.example.com',
        username: 'alice',
        password: 'pw',
      );

      expect(session.serverName, 'Fetched');
      expect(session.serverVersion, '10.10.3');
    });

    test('still signs in when reading server info fails', () async {
      // A public-info hiccup must not block an otherwise-valid sign-in; the
      // session just lacks the version.
      final client = FakeJellyfinClient(
        serverInfoError: JellyfinException.notReachable(),
        authResult: const JellyfinAuthResult(
          accessToken: 'tok',
          userId: 'u-1',
        ),
      );

      final session = await _authenticator(client).signIn(
        rawUrl: 'music.example.com',
        username: 'alice',
        password: 'pw',
      );

      expect(session.accessToken, 'tok');
      expect(session.serverVersion, isNull);
    });

    test('forwards the password to the client (and never returns it)',
        () async {
      final client = FakeJellyfinClient();

      final session = await _authenticator(client).signIn(
        rawUrl: 'https://example.com',
        username: 'alice',
        password: 'hunter2-secret',
      );

      // The password reached the client for the exchange...
      expect(client.lastPassword, 'hunter2-secret');
      // ...but is nowhere in the resulting session.
      expect(session.toString(), isNot(contains('hunter2-secret')));
      expect(session.accessToken, isNot(contains('hunter2-secret')));
    });

    test('rejects an empty username without calling the client', () async {
      final client = FakeJellyfinClient();

      await expectLater(
        _authenticator(client).signIn(
          rawUrl: 'https://example.com',
          username: '   ',
          password: 'pw',
        ),
        throwsA(isA<JellyfinException>()),
      );
      expect(client.lastUsername, isNull);
    });

    test('propagates an auth failure from the client', () async {
      final client =
          FakeJellyfinClient(authError: JellyfinException.unauthorized());

      await expectLater(
        _authenticator(client).signIn(
          rawUrl: 'https://example.com',
          username: 'alice',
          password: 'wrong',
        ),
        throwsA(isA<JellyfinException>().having(
          (JellyfinException e) => e.kind,
          'kind',
          JellyfinErrorKind.unauthorized,
        )),
      );
    });
  });
}
