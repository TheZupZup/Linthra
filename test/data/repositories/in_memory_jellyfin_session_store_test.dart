import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';

const _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'token',
  deviceId: 'device-1',
  userName: 'alice',
);

void main() {
  group('InMemoryJellyfinSessionStore', () {
    test('starts empty by default', () async {
      final store = InMemoryJellyfinSessionStore();
      expect(await store.read(), isNull);
    });

    test('exposes an initial session', () async {
      final store = InMemoryJellyfinSessionStore(initialSession: _session);
      expect(await store.read(), _session);
    });

    test('write then read returns the session', () async {
      final store = InMemoryJellyfinSessionStore();
      await store.write(_session);
      expect(await store.read(), _session);
    });

    test('clear forgets the session', () async {
      final store = InMemoryJellyfinSessionStore(initialSession: _session);
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
