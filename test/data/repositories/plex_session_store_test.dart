import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';

const _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'tok-123',
  machineIdentifier: 'machine-abc',
  serverName: 'Living Room PMS',
  serverVersion: '1.40.1',
  clientIdentifier: 'install-uuid-1',
  selectedSectionKeys: <String>['5', '12'],
);

void main() {
  group('InMemoryPlexSessionStore', () {
    test('starts empty by default', () async {
      final store = InMemoryPlexSessionStore();
      expect(await store.read(), isNull);
    });

    test('exposes an initial session', () async {
      final store = InMemoryPlexSessionStore(initialSession: _session);
      expect(await store.read(), _session);
    });

    test('write then read returns the session', () async {
      final store = InMemoryPlexSessionStore();
      await store.write(_session);
      expect(await store.read(), _session);
    });

    test('clear forgets the session (sign out)', () async {
      final store = InMemoryPlexSessionStore(initialSession: _session);
      await store.clear();
      expect(await store.read(), isNull);
    });
  });

  group('PlexSession serialization', () {
    test('round-trips through toJson/fromJson with the token preserved', () {
      final restored = PlexSession.fromJson(_session.toJson());
      expect(restored, _session);
      // The encrypted store must be able to persist and restore the token.
      expect(restored!.token, 'tok-123');
      expect(restored.serverName, 'Living Room PMS');
      expect(restored.clientIdentifier, 'install-uuid-1');
      expect(restored.selectedSectionKeys, <String>['5', '12']);
    });

    test('omits the optional fields when absent', () {
      const minimal = PlexSession(
        baseUrl: 'https://plex.example.com',
        token: 'tok',
        machineIdentifier: 'm',
      );
      final json = minimal.toJson();
      expect(json.containsKey('serverName'), isFalse);
      expect(json.containsKey('serverVersion'), isFalse);
      expect(json.containsKey('clientIdentifier'), isFalse);
      expect(json.containsKey('selectedSectionKeys'), isFalse);
      expect(PlexSession.fromJson(json), minimal);
    });

    test('loads a record persisted before section selection existed', () {
      // The shape SecurePlexSessionStore wrote under plex_session_v1 before
      // serverName/clientIdentifier/selectedSectionKeys were added.
      const legacy = <String, dynamic>{
        'baseUrl': 'https://plex.example.com:32400',
        'token': 'tok-123',
        'machineIdentifier': 'machine-abc',
        'serverVersion': '1.40.1',
      };
      final restored = PlexSession.fromJson(legacy);
      expect(restored, isNotNull);
      expect(restored!.token, 'tok-123');
      expect(restored.serverName, isNull);
      expect(restored.clientIdentifier, isNull);
      expect(restored.selectedSectionKeys, isEmpty);
    });

    test('returns null when a required field is missing or blank', () {
      const noBaseUrl = <String, dynamic>{
        'token': 'tok',
        'machineIdentifier': 'm',
      };
      const blankToken = <String, dynamic>{
        'baseUrl': 'https://plex.example.com',
        'token': '',
        'machineIdentifier': 'm',
      };
      const noMachineId = <String, dynamic>{
        'baseUrl': 'https://plex.example.com',
        'token': 'tok',
      };

      // A partially written / corrupted record reads back as "signed out".
      expect(PlexSession.fromJson(noBaseUrl), isNull);
      expect(PlexSession.fromJson(blankToken), isNull);
      expect(PlexSession.fromJson(noMachineId), isNull);
    });
  });

  group('PlexSession value semantics', () {
    test('equality covers the selected section keys', () {
      expect(_session, _session.copyWith());
      expect(
        _session,
        isNot(_session.copyWith(selectedSectionKeys: <String>['5'])),
      );
    });

    test('copyWith replaces the selection (the library picker path)', () {
      const fresh = PlexSession(
        baseUrl: 'https://plex.example.com',
        token: 'tok',
        machineIdentifier: 'm',
      );
      expect(fresh.selectedSectionKeys, isEmpty);

      final picked = fresh.copyWith(selectedSectionKeys: <String>['3']);
      expect(picked.selectedSectionKeys, <String>['3']);
      // The token and server identity ride along untouched.
      expect(picked.token, 'tok');
      expect(picked.machineIdentifier, 'm');
    });
  });

  group('token redaction', () {
    test('toString redacts the token, keeps metadata visible', () {
      final text = _session.toString();
      expect(text, isNot(contains('tok-123')));
      expect(text, contains('<redacted>'));
      // Server metadata stays visible for diagnostics.
      expect(text, contains('machine-abc'));
      expect(text, contains('plex.example.com'));
      expect(text, contains('Living Room PMS'));
    });

    test('the token lives only in the persisted JSON, not in toString', () {
      // toJson is the store-only sink that carries the token...
      expect(_session.toJson()['token'], 'tok-123');
      // ...and the human/log-facing string form never does.
      expect(_session.toString(), isNot(contains('tok-123')));
    });
  });
}
