import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/plex/plex_session_fingerprint.dart';

PlexSession _session({
  String machine = 'server-1',
  String token = 'owner-token',
}) =>
    PlexSession(
      baseUrl: 'https://plex.example.com:32400',
      token: token,
      machineIdentifier: machine,
    );

void main() {
  group('plexSessionFingerprint', () {
    test('tells two Home profiles on the same server apart', () {
      expect(
        plexSessionFingerprint(_session(token: 'owner-token')),
        isNot(plexSessionFingerprint(_session(token: 'kid-profile-token'))),
      );
    });

    test('is stable for the same server and profile', () {
      expect(
        plexSessionFingerprint(_session()),
        plexSessionFingerprint(_session()),
      );
    });

    test('changes with the server', () {
      expect(
        plexSessionFingerprint(_session(machine: 'server-1')),
        isNot(plexSessionFingerprint(_session(machine: 'server-2'))),
      );
    });

    test('carries nothing of the token or the server id', () {
      final String fingerprint = plexSessionFingerprint(_session());

      expect(fingerprint, isNot(contains('owner-token')));
      expect(fingerprint, isNot(contains('server-1')));
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });
}
