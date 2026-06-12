import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_authenticator.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';

import 'fake_plex_client.dart';

void main() {
  late FakePlexClient client;

  PlexAuthenticator auth() => PlexAuthenticator(client);

  setUp(() => client = FakePlexClient());

  group('PlexAuthenticator.testConnection', () {
    test('normalizes the URL, sends the token as given, returns identity',
        () async {
      client.identity = const PlexServerIdentity(
        machineIdentifier: 'machine-abc',
        version: '1.40.1',
      );

      final identity = await auth().testConnection(
        rawUrl: 'plex.example.com',
        token: '  tok-123  ',
      );

      expect(identity.machineIdentifier, 'machine-abc');
      // Bare host got the https scheme; the pasted token was trimmed first.
      expect(client.lastBaseUrl, 'https://plex.example.com');
      expect(client.lastToken, 'tok-123');
    });

    test('rejects an empty token before any network call', () async {
      await expectLater(
        auth().testConnection(rawUrl: 'plex.example.com', token: '   '),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unauthorized)),
      );
      expect(client.lastToken, isNull); // never reached the client
    });

    test('throws an invalidUrl before touching the client', () async {
      await expectLater(
        auth().testConnection(rawUrl: '   ', token: 'tok'),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.invalidUrl)),
      );
      expect(client.lastBaseUrl, isNull);
    });
  });

  group('PlexAuthenticator.signIn', () {
    test('produces a session storing the token + server metadata', () async {
      client.identity = const PlexServerIdentity(
        machineIdentifier: 'machine-abc',
        version: '1.40.1',
      );

      final session = await auth().signIn(
        rawUrl: 'https://plex.example.com:32400/',
        token: 'tok-123',
      );

      // Trailing slash stripped; explicit port preserved.
      expect(session.baseUrl, 'https://plex.example.com:32400');
      expect(session.token, 'tok-123');
      expect(session.machineIdentifier, 'machine-abc');
      expect(session.serverVersion, '1.40.1');
      expect(client.lastToken, 'tok-123');
      // The manual flow has no friendly name (/identity doesn't report one)
      // and no libraries picked yet — the picker PR fills the selection.
      expect(session.serverName, isNull);
      expect(session.selectedSectionKeys, isEmpty);
    });

    test('surfaces a rejected token as unauthorized (invalid token)', () async {
      client.identityError = PlexException.unauthorized();
      await expectLater(
        auth().signIn(rawUrl: 'plex.example.com', token: 'bad-token'),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unauthorized)),
      );
    });

    test('surfaces an unreachable server', () async {
      client.identityError = PlexException.notReachable();
      await expectLater(
        auth().signIn(rawUrl: 'plex.example.com', token: 'tok'),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notReachable)),
      );
    });

    test('surfaces an address that is not a Plex server', () async {
      client.identityError = PlexException.notPlex();
      await expectLater(
        auth().signIn(rawUrl: 'plex.example.com', token: 'tok'),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.notPlex)),
      );
    });

    test('propagates a malformed/unsupported response unchanged', () async {
      // A Plex-shaped body Linthra can't use (an unexpected shape from an older/
      // newer server) reaches the UI as-is; the authenticator is a transparent
      // propagator and transforms no error kinds.
      client.identityError = PlexException.unsupportedResponse();
      await expectLater(
        auth().signIn(rawUrl: 'plex.example.com', token: 'tok'),
        throwsA(isA<PlexException>()
            .having((e) => e.kind, 'kind', PlexErrorKind.unsupportedResponse)),
      );
    });

    test('rejects an empty token without calling the client', () async {
      await expectLater(
        auth().signIn(rawUrl: 'plex.example.com', token: ''),
        throwsA(isA<PlexException>()),
      );
      expect(client.lastToken, isNull);
    });
  });

  group('token safety', () {
    test('the returned session redacts the token in toString', () async {
      final session = await auth().signIn(
        rawUrl: 'plex.example.com',
        token: 'super-secret-token',
      );

      // Stored for use by the client...
      expect(session.token, 'super-secret-token');
      // ...but never present in the string form.
      expect(session.toString(), isNot(contains('super-secret-token')));
      expect(session.toString(), contains('<redacted>'));
    });

    test('a thrown error never carries the token', () async {
      client.identityError = PlexException.unauthorized();

      try {
        await auth().signIn(
          rawUrl: 'plex.example.com',
          token: 'super-secret-token',
        );
        fail('expected a PlexException');
      } on PlexException catch (e) {
        expect(e.message, isNot(contains('super-secret-token')));
        expect(e.toString(), isNot(contains('super-secret-token')));
      }
    });
  });
}
