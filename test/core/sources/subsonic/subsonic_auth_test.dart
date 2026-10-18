import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_endpoints.dart';

void main() {
  group('SubsonicAuth.tokenFor', () {
    test('is md5(password + salt) — known MD5 vectors', () {
      // md5('a') = 0cc175b9c0f1b6a831c399e269772661
      expect(
          SubsonicAuth.tokenFor('a', ''), '0cc175b9c0f1b6a831c399e269772661');
      expect(
          SubsonicAuth.tokenFor('', 'a'), '0cc175b9c0f1b6a831c399e269772661');
      // md5('ab') = 187ef4436122d1cc2f40dc2b92f0eba0 (password+salt is concat)
      expect(
          SubsonicAuth.tokenFor('a', 'b'), '187ef4436122d1cc2f40dc2b92f0eba0');
      expect(
          SubsonicAuth.tokenFor('ab', ''), '187ef4436122d1cc2f40dc2b92f0eba0');
    });

    test('is a 32-char lowercase hex digest', () {
      final String token = SubsonicAuth.tokenFor('hunter2', 'abc123');
      expect(token, hasLength(32));
      expect(token, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('changes with the password', () {
      expect(
        SubsonicAuth.tokenFor('one', 'salt'),
        isNot(SubsonicAuth.tokenFor('two', 'salt')),
      );
    });
  });

  group('SubsonicAuth.credentials', () {
    test('uses the injected salt and derives the matching token', () {
      final creds = SubsonicAuth.credentials(
        'hunter2',
        saltGenerator: () => 'fixedsalt',
      );
      expect(creds.salt, 'fixedsalt');
      expect(creds.token, SubsonicAuth.tokenFor('hunter2', 'fixedsalt'));
    });

    test('generates a fresh random salt by default', () {
      final a = SubsonicAuth.credentials('pw');
      final b = SubsonicAuth.credentials('pw');
      expect(a.salt, isNot(b.salt));
      expect(a.salt, isNotEmpty);
    });
  });

  group('security', () {
    test('toString redacts the salt and token', () {
      final creds = SubsonicAuth.credentials(
        'hunter2',
        saltGenerator: () => 'fixedsalt',
      );
      final String text = creds.toString();
      expect(text, isNot(contains('fixedsalt')));
      expect(text, isNot(contains(creds.token)));
      expect(text, contains('<redacted>'));
    });

    test('the plaintext password never appears in the credential', () {
      final creds = SubsonicAuth.credentials(
        'super-secret-password',
        saltGenerator: () => 'fixedsalt',
      );
      expect(creds.salt, isNot(contains('super-secret-password')));
      expect(creds.token, isNot(contains('super-secret-password')));
    });
  });

  group('SubsonicAuth legacy mode', () {
    test('legacy credentials produce correct password parameter and flag', () {
      const creds = SubsonicCredentials.legacy('mysecretpassword');
      expect(creds.isLegacy, isTrue);
      expect(creds.password, 'mysecretpassword');
    });

    test('legacy credentials redact password in toString()', () {
      const creds = SubsonicCredentials.legacy('mysecretpassword');
      final text = creds.toString();
      expect(text, isNot(contains('mysecretpassword')));
      expect(text, contains('<redacted>'));
    });

    test('SubsonicEndpoints builds URI with p=password in legacy mode', () {
      final uri = SubsonicEndpoints.stream(
        'https://music.example.com',
        username: 'testuser',
        credentials: const SubsonicCredentials.legacy('secret123'),
        songId: 'song-xyz',
      );

      expect(uri.queryParameters['u'], 'testuser');
      expect(uri.queryParameters['p'], 'secret123');
      expect(uri.queryParameters.containsKey('t'), isFalse);
      expect(uri.queryParameters.containsKey('s'), isFalse);
    });

    test('SubsonicSession serializes and deserializes legacy state correctly',
        () {
      const session = SubsonicSession(
        baseUrl: 'https://music.example.com',
        username: 'testuser',
        isLegacy: true,
        password: 'secret123',
      );

      final json = session.toJson();
      final restored = SubsonicSession.fromJson(json);

      expect(restored?.isLegacy, isTrue);
      expect(restored?.password, 'secret123');
      expect(restored?.token, isNull);
      expect(restored?.salt, isNull);
    });
  });
}
