import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';

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
}
