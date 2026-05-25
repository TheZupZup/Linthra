import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';

void main() {
  const session = SubsonicSession(
    baseUrl: 'https://music.example.com',
    username: 'alice',
    salt: 'abc123salt',
    token: 'deadbeefdeadbeefdeadbeefdeadbeef',
    serverType: 'navidrome',
    serverVersion: '0.52.0',
    apiVersion: '1.16.1',
  );

  group('SubsonicSession serialization', () {
    test('round-trips through toJson/fromJson', () {
      final restored = SubsonicSession.fromJson(session.toJson());
      expect(restored, session);
    });

    test('fromJson returns null when a required field is missing', () {
      expect(
        SubsonicSession.fromJson(<String, dynamic>{
          'baseUrl': 'https://x',
          'username': 'a',
          // no salt/token
        }),
        isNull,
      );
      expect(
        SubsonicSession.fromJson(<String, dynamic>{
          'baseUrl': '',
          'username': 'a',
          'salt': 's',
          'token': 't',
        }),
        isNull,
      );
    });
  });

  group('security', () {
    test('toString redacts the salt and token', () {
      final String text = session.toString();
      expect(text, isNot(contains('abc123salt')));
      expect(text, isNot(contains('deadbeefdeadbeefdeadbeefdeadbeef')));
      expect(text, contains('<redacted>'));
      // Non-secret display fields are fine to show.
      expect(text, contains('music.example.com'));
      expect(text, contains('alice'));
    });

    test('has no password field at all (only the derived credential)', () {
      // The serialized form carries the salt+token, never a password key.
      expect(session.toJson().containsKey('password'), isFalse);
    });
  });
}
