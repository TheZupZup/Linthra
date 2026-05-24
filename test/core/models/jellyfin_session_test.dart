import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'secret-token-value',
  deviceId: 'device-1',
  userName: 'alice',
  serverId: 'server-1',
  serverName: 'My Server',
  serverVersion: '10.9.11',
  productName: 'Jellyfin Server',
);

void main() {
  group('JellyfinSession', () {
    test('round-trips through toJson/fromJson', () {
      final restored = JellyfinSession.fromJson(_session.toJson());
      expect(restored, _session);
    });

    test('round-trips the server version and product for diagnostics', () {
      final restored = JellyfinSession.fromJson(_session.toJson());
      expect(restored!.serverVersion, '10.9.11');
      expect(restored.productName, 'Jellyfin Server');
    });

    test('the server version/product are not secret and survive toString', () {
      // They are display/diagnostics fields, so they may appear in toString —
      // unlike the token, which must stay redacted.
      final String text = _session.toString();
      expect(text, contains('10.9.11'));
      expect(text, isNot(contains('secret-token-value')));
    });

    test('fromJson returns null when a required field is missing', () {
      final json = _session.toJson()..remove('accessToken');
      expect(JellyfinSession.fromJson(json), isNull);
    });

    test('fromJson returns null when a required field is blank', () {
      final json = _session.toJson();
      json['deviceId'] = '';
      expect(JellyfinSession.fromJson(json), isNull);
    });

    test('toString redacts the access token', () {
      final String text = _session.toString();
      expect(text, isNot(contains('secret-token-value')));
      expect(text, contains('<redacted>'));
      // Non-secret fields are fine to show.
      expect(text, contains('user-1'));
    });

    test('copyWith updates only the named fields', () {
      final updated = _session.copyWith(serverName: 'Renamed');
      expect(updated.serverName, 'Renamed');
      expect(updated.accessToken, _session.accessToken);
      expect(updated.baseUrl, _session.baseUrl);
    });
  });
}
