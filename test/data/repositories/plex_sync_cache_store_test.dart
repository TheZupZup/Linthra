import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/plex_sync_cache_store.dart';
import 'package:linthra/data/repositories/in_memory_plex_sync_cache_store.dart';
import 'package:linthra/data/repositories/shared_preferences_plex_sync_cache_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // Both bindings must satisfy the same contract, so they share one test body.
  final Map<String, PlexSyncCacheStore Function()> impls =
      <String, PlexSyncCacheStore Function()>{
    'InMemoryPlexSyncCacheStore': InMemoryPlexSyncCacheStore.new,
    'SharedPreferencesPlexSyncCacheStore':
        SharedPreferencesPlexSyncCacheStore.new,
  };

  for (final MapEntry<String, PlexSyncCacheStore Function()> entry
      in impls.entries) {
    group(entry.key, () {
      test('reads null when nothing is stored', () async {
        expect(await entry.value().readSignature('machine-1'), isNull);
      });

      test('round-trips a signature for the same server', () async {
        final PlexSyncCacheStore store = entry.value();
        await store.writeSignature('machine-1', 'sig-abc');
        expect(await store.readSignature('machine-1'), 'sig-abc');
      });

      test('returns null for a different server (never a stale fingerprint)',
          () async {
        final PlexSyncCacheStore store = entry.value();
        await store.writeSignature('machine-1', 'sig-abc');
        expect(await store.readSignature('machine-2'), isNull);
      });

      test('a later write replaces the previous record', () async {
        final PlexSyncCacheStore store = entry.value();
        await store.writeSignature('machine-1', 'sig-old');
        await store.writeSignature('machine-1', 'sig-new');
        expect(await store.readSignature('machine-1'), 'sig-new');
      });

      test('reconnecting to a different server replaces the record', () async {
        final PlexSyncCacheStore store = entry.value();
        await store.writeSignature('machine-1', 'sig-1');
        await store.writeSignature('machine-2', 'sig-2');
        expect(await store.readSignature('machine-1'), isNull);
        expect(await store.readSignature('machine-2'), 'sig-2');
      });

      test('clear forgets the stored signature', () async {
        final PlexSyncCacheStore store = entry.value();
        await store.writeSignature('machine-1', 'sig-abc');
        await store.clear();
        expect(await store.readSignature('machine-1'), isNull);
      });
    });
  }

  group('SharedPreferencesPlexSyncCacheStore (persistence specifics)', () {
    test('a written signature survives a fresh store instance', () async {
      await const SharedPreferencesPlexSyncCacheStore()
          .writeSignature('machine-1', 'sig-abc');

      // A brand-new instance (e.g. after a restart) still reads it back.
      expect(
        await const SharedPreferencesPlexSyncCacheStore()
            .readSignature('machine-1'),
        'sig-abc',
      );
    });

    test('a corrupt value reads as no record rather than throwing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'plex_sync_cache_v1': 'not-json',
      });
      expect(
        await const SharedPreferencesPlexSyncCacheStore()
            .readSignature('machine-1'),
        isNull,
      );
    });

    test('stores no secret — only the server id and signature it was given',
        () async {
      await const SharedPreferencesPlexSyncCacheStore()
          .writeSignature('machine-1', '5|2|123456');

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw = prefs.getString('plex_sync_cache_v1')!;
      // The persisted blob is exactly the (non-secret) machine id + signature.
      expect(raw, contains('machine-1'));
      expect(raw, contains('5|2|123456'));
    });
  });
}
