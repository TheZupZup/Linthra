import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt-value',
  token: 'super-secret-token-value',
);

void main() {
  group('subsonicAccountFingerprint', () {
    test('is stable for the same server + account', () {
      expect(
        subsonicAccountFingerprint(_session),
        subsonicAccountFingerprint(_session),
      );
    });

    test('changes when the server URL changes', () {
      final other = _session.copyWith(baseUrl: 'https://other.example.com');
      expect(
        subsonicAccountFingerprint(other),
        isNot(subsonicAccountFingerprint(_session)),
      );
    });

    test('changes when the user changes', () {
      final other = _session.copyWith(username: 'bob');
      expect(
        subsonicAccountFingerprint(other),
        isNot(subsonicAccountFingerprint(_session)),
      );
    });

    test('a credential change alone never changes the fingerprint', () {
      // It identifies the *account*, not the session secret — so a fresh
      // salt/token (a re-login to the same account) is still "the same account".
      final reauthed = _session.copyWith(salt: 'new-salt', token: 'new-token');
      expect(
        subsonicAccountFingerprint(reauthed),
        subsonicAccountFingerprint(_session),
      );
    });

    test('does not contain the credentials, the URL, or the username', () {
      // A one-way hash: it must reveal no secret and no identifying value.
      final String fingerprint = subsonicAccountFingerprint(_session);
      expect(fingerprint, isNot(contains('super-secret-token-value')));
      expect(fingerprint, isNot(contains('salt-value')));
      expect(fingerprint, isNot(contains('music.example.com')));
      expect(fingerprint, isNot(contains('alice')));
      // A hex SHA-256 digest.
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('subsonicServerFingerprint', () {
    test('is the same for every account on one server', () {
      // A song id is the server's, so another user's copies still match.
      final other = _session.copyWith(username: 'bob', token: 'bob-token');
      expect(
        subsonicServerFingerprint(other),
        subsonicServerFingerprint(_session),
      );
    });

    test('changes when the server URL changes', () {
      final other = _session.copyWith(baseUrl: 'https://other.example.com');
      expect(
        subsonicServerFingerprint(other),
        isNot(subsonicServerFingerprint(_session)),
      );
    });

    test('tells two Navidrome installations apart by their address', () {
      // Navidrome's ids come from file paths, and another installation can
      // have another file at the same path.
      final one = _session.copyWith(serverType: 'navidrome');
      final other = one.copyWith(baseUrl: 'https://other.example.com');
      expect(
        subsonicServerFingerprint(other),
        isNot(subsonicServerFingerprint(one)),
      );
    });

    test('does not contain the credentials or the URL', () {
      final String fingerprint = subsonicServerFingerprint(_session);
      expect(fingerprint, isNot(contains('super-secret-token-value')));
      expect(fingerprint, isNot(contains('salt-value')));
      expect(fingerprint, isNot(contains('music.example.com')));
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });
}
