import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_account_fingerprint.dart';

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'super-secret-token-value',
  deviceId: 'device-1',
  userName: 'alice',
);

void main() {
  group('jellyfinAccountFingerprint', () {
    test('is stable for the same server + account', () {
      // The same connection always fingerprints the same, so the auto-sync gate
      // can recognise an already-synced account.
      expect(
        jellyfinAccountFingerprint(_session),
        jellyfinAccountFingerprint(_session),
      );
    });

    test('changes when the server URL changes', () {
      final other = _session.copyWith(baseUrl: 'https://other.example.com');
      expect(
        jellyfinAccountFingerprint(other),
        isNot(jellyfinAccountFingerprint(_session)),
      );
    });

    test('changes when the user changes', () {
      final other = _session.copyWith(userId: 'user-2');
      expect(
        jellyfinAccountFingerprint(other),
        isNot(jellyfinAccountFingerprint(_session)),
      );
    });

    test('a token change alone never changes the fingerprint', () {
      // It identifies the *account*, not the session secret — so refreshing the
      // token (a new sign-in to the same account) is still "the same account".
      final reauthed = _session.copyWith(accessToken: 'a-different-token');
      expect(
        jellyfinAccountFingerprint(reauthed),
        jellyfinAccountFingerprint(_session),
      );
    });

    test('does not contain the token, the URL, or the user id', () {
      // The stored fingerprint is a one-way hash: it must reveal no secret and
      // no authenticated/identifying value, since it lives in plain storage.
      final String fingerprint = jellyfinAccountFingerprint(_session);
      expect(fingerprint, isNot(contains('super-secret-token-value')));
      expect(fingerprint, isNot(contains('music.example.com')));
      expect(fingerprint, isNot(contains('user-1')));
      expect(fingerprint, isNot(contains('alice')));
      // A hex SHA-256 digest.
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });
}
