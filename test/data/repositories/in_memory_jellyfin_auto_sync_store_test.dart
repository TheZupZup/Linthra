import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_auto_sync_store.dart';

void main() {
  group('InMemoryJellyfinAutoSyncStore', () {
    test('reads null before anything is written', () async {
      final store = InMemoryJellyfinAutoSyncStore();
      expect(await store.read(), isNull);
    });

    test('round-trips a written fingerprint', () async {
      final store = InMemoryJellyfinAutoSyncStore();
      await store.write('abc123');
      expect(await store.read(), 'abc123');
    });

    test('a later write replaces the earlier fingerprint', () async {
      final store = InMemoryJellyfinAutoSyncStore();
      await store.write('first');
      await store.write('second');
      expect(await store.read(), 'second');
    });

    test('clear forgets the fingerprint', () async {
      final store = InMemoryJellyfinAutoSyncStore('seeded');
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
