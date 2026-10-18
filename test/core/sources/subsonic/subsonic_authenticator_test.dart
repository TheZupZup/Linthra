import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_authenticator.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';

import 'fake_subsonic_client.dart';

void main() {
  late FakeSubsonicClient client;

  SubsonicAuthenticator auth() => SubsonicAuthenticator(
        client,
        saltGenerator: () => 'fixedsalt',
      );

  setUp(() => client = FakeSubsonicClient());

  group('testConnection', () {
    test('normalizes the URL and pings with derived credentials', () async {
      final info = await auth().testConnection(
        rawUrl: 'music.example.com',
        username: ' alice ',
        password: 'hunter2',
      );

      expect(info.type, 'navidrome');
      expect(client.lastBaseUrl, 'https://music.example.com');
      expect(client.lastUsername, 'alice');
      // The token is md5(password + salt) for the fixed salt — never the
      // password itself.
      expect(client.lastCredentials!.salt, 'fixedsalt');
      expect(
        client.lastCredentials!.token,
        SubsonicAuth.tokenFor('hunter2', 'fixedsalt'),
      );
      expect(client.lastCredentials!.token, isNot(contains('hunter2')));
    });

    test('surfaces a rejected credential as unauthorized', () async {
      client.pingError = SubsonicException.unauthorized();
      expect(
        () => auth().testConnection(
          rawUrl: 'music.example.com',
          username: 'alice',
          password: 'wrong',
        ),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.unauthorized)),
      );
    });

    test('rejects an empty username/password before any network call',
        () async {
      await expectLater(
        auth().testConnection(
            rawUrl: 'music.example.com', username: '  ', password: 'x'),
        throwsA(isA<SubsonicException>()),
      );
      await expectLater(
        auth().testConnection(
            rawUrl: 'music.example.com', username: 'a', password: ''),
        throwsA(isA<SubsonicException>()),
      );
      expect(client.lastBaseUrl, isNull); // never reached the client
    });
  });

  group('signIn', () {
    test('produces a session that stores only the derived credential',
        () async {
      client.serverInfo = const SubsonicServerInfo(
        apiVersion: '1.16.1',
        type: 'navidrome',
        serverVersion: '0.52.0',
      );

      final session = await auth().signIn(
        rawUrl: 'https://music.example.com/',
        username: 'alice',
        password: 'hunter2',
      );

      expect(session.baseUrl, 'https://music.example.com');
      expect(session.username, 'alice');
      expect(session.salt, 'fixedsalt');
      expect(session.token, SubsonicAuth.tokenFor('hunter2', 'fixedsalt'));
      expect(session.serverType, 'navidrome');
      expect(session.serverVersion, '0.52.0');
      // The password is not anywhere in the session.
      expect(session.toJson().values.contains('hunter2'), isFalse);
    });

    test('throws on a bad URL before deriving anything', () {
      expect(
        () => auth().signIn(rawUrl: '', username: 'a', password: 'b'),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.invalidUrl)),
      );
    });
  });

  group('legacy sign-in', () {
    test('keeps the password for an https server', () async {
      final session = await auth().signIn(
        rawUrl: 'https://cloud.example.com/apps/music/subsonic',
        username: 'alice',
        password: 'api-key',
        useLegacy: true,
      );

      expect(session.isLegacy, isTrue);
      expect(session.password, 'api-key');
      expect(session.token, isNull);
      expect(client.lastCredentials!.password, 'api-key');
    });

    test('a bare address is https, so it works there too', () async {
      final session = await auth().signIn(
        rawUrl: 'cloud.example.com',
        username: 'alice',
        password: 'api-key',
        useLegacy: true,
      );
      expect(session.baseUrl, 'https://cloud.example.com');
    });

    test('is refused for http before anything is sent', () async {
      await expectLater(
        auth().testConnection(
          rawUrl: 'http://192.168.1.50:8080',
          username: 'alice',
          password: 'api-key',
          useLegacy: true,
        ),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.cleartextBlocked)),
      );
      await expectLater(
        auth().signIn(
          rawUrl: 'http://192.168.1.50:8080',
          username: 'alice',
          password: 'api-key',
          useLegacy: true,
        ),
        throwsA(isA<SubsonicException>()
            .having((e) => e.kind, 'kind', SubsonicErrorKind.cleartextBlocked)),
      );
      expect(client.lastCredentials, isNull);
    });

    test('token sign-in over http is unchanged', () async {
      final session = await auth().signIn(
        rawUrl: 'http://192.168.1.50:4533',
        username: 'alice',
        password: 'hunter2',
      );
      expect(session.isLegacy, isFalse);
      expect(session.password, isNull);
      expect(session.token, SubsonicAuth.tokenFor('hunter2', 'fixedsalt'));
    });
  });
}
