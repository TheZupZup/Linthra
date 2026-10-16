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

  // Opt-in legacy password sign-in, for a server that refuses the token.
  group('password session', () {
    const password = SubsonicSession.password(
      baseUrl: 'https://cloud.example.com/apps/music/subsonic',
      username: 'alice',
      password: 'app-password',
      serverType: 'Nextcloud Music',
    );

    test('round-trips through toJson/fromJson', () {
      final restored = SubsonicSession.fromJson(password.toJson());
      expect(restored, password);
      expect(restored!.usesPassword, isTrue);
      expect(restored.salt, isNull);
      expect(restored.token, isNull);
    });

    test('is marked as one, and carries no salt or token', () {
      final json = password.toJson();
      expect(json['auth'], 'password');
      expect(json.containsKey('salt'), isFalse);
      expect(json.containsKey('token'), isFalse);
    });

    test('a salt+token record is written exactly as before', () {
      expect(session.toJson().keys, <String>[
        'baseUrl',
        'username',
        'salt',
        'token',
        'serverType',
        'serverVersion',
        'apiVersion',
      ]);
      expect(session.usesPassword, isFalse);
    });

    test('a record saved before password sign-in restores as salt+token', () {
      final restored = SubsonicSession.fromJson(<String, dynamic>{
        'baseUrl': 'https://music.example.com',
        'username': 'alice',
        'salt': 'abc123salt',
        'token': 'deadbeef',
      });
      expect(restored, isNotNull);
      expect(restored!.usesPassword, isFalse);
      expect(restored.token, 'deadbeef');
    });

    test('is never restored for an http server', () {
      expect(
        SubsonicSession.fromJson(<String, dynamic>{
          'baseUrl': 'http://192.168.1.20:8080',
          'username': 'alice',
          'auth': 'password',
          'password': 'app-password',
        }),
        isNull,
      );
    });

    test('reads as signed out without a usable password', () {
      for (final Object? value in <Object?>[null, '', 42]) {
        expect(
          SubsonicSession.fromJson(<String, dynamic>{
            'baseUrl': 'https://cloud.example.com',
            'username': 'alice',
            'auth': 'password',
            'password': value,
          }),
          isNull,
          reason: 'password: $value',
        );
      }
    });

    test('toString redacts the password', () {
      final String text = password.toString();
      expect(text, isNot(contains('app-password')));
      expect(text, contains('password: <redacted>'));
      expect(text, contains('alice'));
    });

    test('copyWith keeps the password', () {
      final moved = password.copyWith(baseUrl: 'https://other.example.com');
      expect(moved.usesPassword, isTrue);
      expect(moved.password, 'app-password');
      expect(moved.baseUrl, 'https://other.example.com');
    });
  });
}
