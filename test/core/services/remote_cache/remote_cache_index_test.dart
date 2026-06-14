import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_index.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';

import 'fake_remote_cache_store.dart';

RemoteCacheEntry _entry(
  String uri, {
  required DateTime now,
  String token = 'SECRET',
}) =>
    RemoteCacheEntry(
      key: RemoteCacheKey.forUri(uri)!,
      streamUri: Uri.parse('https://server.example/stream?api_key=$token'),
      source: PlaybackSource.streamingDirect,
      resolvedAt: now,
      expiresAt: now.add(const Duration(minutes: 2)),
    );

RemoteCacheRecord _record(
  String uri, {
  required DateTime recordedAt,
  required DateTime expiresAt,
}) =>
    RemoteCacheRecord.fromEntry(
      _entry(uri, now: recordedAt),
      recordedAt: recordedAt,
      expiresAt: expiresAt,
    );

void main() {
  final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);

  group('RemoteCacheIndex.record', () {
    test('records a warmed track and persists its credential-free key',
        () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.record(_entry('jellyfin:a', now: now));

      expect(index.length, 1);
      expect(index.records.single.value, 'jellyfin:a');
      expect(store.saved.single.value, 'jellyfin:a');
    });

    test('routes Jellyfin, Subsonic and Plex into one index', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.record(_entry('jellyfin:j', now: now));
      await index.record(_entry('subsonic:s', now: now));
      await index.record(_entry('plex:1', now: now));

      expect(
        index.records.map((RemoteCacheRecord r) => r.sourceId).toSet(),
        <String>{'jellyfin', 'subsonic', 'plex'},
      );
      expect(index.length, 3);
    });

    test(
        're-warming the same key replaces rather than duplicates (newest wins)',
        () async {
      DateTime clock = now;
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => clock);

      await index.record(_entry('plex:1', now: clock));
      clock = now.add(const Duration(minutes: 5));
      await index.record(_entry('plex:1', now: clock));

      expect(index.length, 1);
      expect(index.records.single.recordedAt, clock);
    });
  });

  group('RemoteCacheIndex.load (survives a restart)', () {
    test('loads persisted records so the cache knowledge survives a restart',
        () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(
        seed: <RemoteCacheRecord>[
          _record('jellyfin:a',
              recordedAt: now, expiresAt: now.add(const Duration(days: 30))),
        ],
      );
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.load();

      expect(index.length, 1);
      expect(index.records.single.value, 'jellyfin:a');
    });

    test('prunes records already expired at load and rewrites the manifest',
        () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(
        seed: <RemoteCacheRecord>[
          _record('jellyfin:old',
              recordedAt: now.subtract(const Duration(days: 40)),
              expiresAt: now.subtract(const Duration(days: 1))),
          _record('jellyfin:fresh',
              recordedAt: now, expiresAt: now.add(const Duration(days: 30))),
        ],
      );
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.load();

      expect(index.records.map((RemoteCacheRecord r) => r.value),
          <String>['jellyfin:fresh']);
      expect(store.saveCount, 1); // the pruned set was written back
      expect(store.saved.map((RemoteCacheRecord r) => r.value),
          <String>['jellyfin:fresh']);
    });

    test('a clean manifest at load does no redundant write', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(
        seed: <RemoteCacheRecord>[
          _record('jellyfin:a',
              recordedAt: now, expiresAt: now.add(const Duration(days: 30))),
        ],
      );
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.load();

      expect(store.loadCount, 1);
      expect(store.saveCount, 0);
    });

    test('loads at most once, even across many calls', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.load();
      await index.load();
      await index.record(_entry('jellyfin:a', now: now));

      expect(store.loadCount, 1);
    });
  });

  group('RemoteCacheIndex.sweep', () {
    test('drops records that expired since they were recorded', () async {
      DateTime clock = now;
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index = RemoteCacheIndex(
        store: store,
        retention: const Duration(minutes: 2),
        clock: () => clock,
      );

      await index.record(_entry('jellyfin:a', now: clock));
      expect(index.length, 1);

      clock = now.add(const Duration(minutes: 3));
      await index.sweep();

      expect(index.length, 0);
      expect(store.saved, isEmpty);
    });

    test('a sweep with nothing stale writes nothing', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index = RemoteCacheIndex(
        store: store,
        retention: const Duration(days: 30),
        clock: () => now,
      );

      await index.record(_entry('jellyfin:a', now: now));
      final int before = store.saveCount;
      await index.sweep();

      expect(index.length, 1);
      expect(store.saveCount, before);
    });
  });

  group('RemoteCacheIndex bounds the manifest', () {
    test('evicts the oldest-recorded entries past the cap', () async {
      DateTime clock = now;
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, maxEntries: 2, clock: () => clock);

      await index.record(_entry('jellyfin:a', now: clock));
      clock = now.add(const Duration(minutes: 1));
      await index.record(_entry('jellyfin:b', now: clock));
      clock = now.add(const Duration(minutes: 2));
      await index.record(_entry('jellyfin:c', now: clock));

      // 'a' (the oldest) is evicted; the two most-recent survive on disk too.
      expect(index.records.map((RemoteCacheRecord r) => r.value).toSet(),
          <String>{'jellyfin:b', 'jellyfin:c'});
      expect(store.saved.map((RemoteCacheRecord r) => r.value).toSet(),
          <String>{'jellyfin:b', 'jellyfin:c'});
    });

    test('trims an over-cap manifest on load', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(
        seed: <RemoteCacheRecord>[
          _record('jellyfin:a',
              recordedAt: now, expiresAt: now.add(const Duration(days: 30))),
          _record('jellyfin:b',
              recordedAt: now.add(const Duration(minutes: 1)),
              expiresAt: now.add(const Duration(days: 30))),
          _record('jellyfin:c',
              recordedAt: now.add(const Duration(minutes: 2)),
              expiresAt: now.add(const Duration(days: 30))),
        ],
      );
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, maxEntries: 2, clock: () => now);

      await index.load();

      expect(index.length, 2);
      expect(index.records.map((RemoteCacheRecord r) => r.value),
          isNot(contains('jellyfin:a')));
      expect(store.saveCount, 1); // the trimmed manifest was written back
    });
  });

  group('RemoteCacheIndex.clear', () {
    test('empties the index and the persisted store', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.record(_entry('jellyfin:a', now: now));
      await index.clear();

      expect(index.length, 0);
      expect(store.saved, isEmpty);
    });
  });

  group('RemoteCacheIndex.removeSource (provider disconnect)', () {
    test('drops only the given provider, keeping the others', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);
      await index.record(_entry('jellyfin:a', now: now));
      await index.record(_entry('jellyfin:b', now: now));
      await index.record(_entry('subsonic:s', now: now));
      await index.record(_entry('plex:1', now: now));

      await index.removeSource('jellyfin');

      expect(index.records.map((RemoteCacheRecord r) => r.value).toSet(),
          <String>{'subsonic:s', 'plex:1'});
      // The removal is persisted, not just dropped from memory.
      expect(store.saved.map((RemoteCacheRecord r) => r.value).toSet(),
          <String>{'subsonic:s', 'plex:1'});
    });

    test('removes each provider in isolation', () async {
      for (final MapEntry<String, Set<String>> expected
          in <String, Set<String>>{
        'jellyfin': <String>{'subsonic:s', 'plex:1'},
        'subsonic': <String>{'jellyfin:a', 'plex:1'},
        'plex': <String>{'jellyfin:a', 'subsonic:s'},
      }.entries) {
        final FakeRemoteCacheStore store = FakeRemoteCacheStore();
        final RemoteCacheIndex index =
            RemoteCacheIndex(store: store, clock: () => now);
        await index.record(_entry('jellyfin:a', now: now));
        await index.record(_entry('subsonic:s', now: now));
        await index.record(_entry('plex:1', now: now));

        await index.removeSource(expected.key);

        expect(index.records.map((RemoteCacheRecord r) => r.value).toSet(),
            expected.value);
      }
    });

    test('loads first, so a cold index still drops persisted records',
        () async {
      // A fresh index (just after launch) still removes the right provider's
      // *persisted* records when a disconnect calls removeSource.
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(
        seed: <RemoteCacheRecord>[
          _record('jellyfin:a',
              recordedAt: now, expiresAt: now.add(const Duration(days: 30))),
          _record('plex:1',
              recordedAt: now, expiresAt: now.add(const Duration(days: 30))),
        ],
      );
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.removeSource('plex');

      expect(index.records.map((RemoteCacheRecord r) => r.value),
          <String>['jellyfin:a']);
      expect(store.saved.map((RemoteCacheRecord r) => r.value),
          <String>['jellyfin:a']);
    });

    test('removing a provider with no records writes nothing', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);
      await index.record(_entry('jellyfin:a', now: now));
      final int before = store.saveCount;

      await index.removeSource('plex'); // nothing of this source to remove

      expect(index.length, 1);
      expect(store.saveCount, before);
    });

    test('a failing store never throws (non-fatal)', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(
        seed: <RemoteCacheRecord>[
          _record('jellyfin:a',
              recordedAt: now, expiresAt: now.add(const Duration(days: 30))),
        ],
        failOnSave: true,
      );
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      // Must not throw even though persisting the removal fails.
      await index.removeSource('jellyfin');

      // Removed from the in-memory view regardless.
      expect(index.length, 0);
    });
  });

  group('RemoteCacheIndex is best-effort (never fatal)', () {
    test('a failing save never throws and keeps the in-memory record',
        () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(failOnSave: true);
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.record(_entry('jellyfin:a', now: now));

      expect(index.length, 1);
    });

    test('a failing load degrades to a cold index without throwing', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(failOnLoad: true);
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.load();
      expect(index.length, 0);

      // A later warm still records (in memory), proving the index keeps working.
      await index.record(_entry('jellyfin:a', now: now));
      expect(index.length, 1);
    });

    test('clear never throws even if the store rejects the write', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore(failOnSave: true);
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.record(_entry('jellyfin:a', now: now));
      await index.clear();

      expect(index.length, 0);
    });
  });

  group('RemoteCacheIndex credential safety', () {
    test('persists no token or URL for a warmed tokenized entry', () async {
      final FakeRemoteCacheStore store = FakeRemoteCacheStore();
      final RemoteCacheIndex index =
          RemoteCacheIndex(store: store, clock: () => now);

      await index.record(_entry('plex:101', now: now, token: 'SUPER-SECRET'));

      final String encoded = jsonEncode(<Map<String, dynamic>>[
        for (final RemoteCacheRecord r in store.saved) r.toJson(),
      ]);
      expect(encoded, isNot(contains('SUPER-SECRET')));
      expect(encoded.toLowerCase(), isNot(contains('token')));
      expect(encoded.toLowerCase(), isNot(contains('api_key')));
      expect(encoded.toLowerCase(), isNot(contains('http')));

      for (final RemoteCacheRecord r in index.records) {
        expect(r.toString(), isNot(contains('SUPER-SECRET')));
        expect(r.fileSafeName, isNot(contains('SUPER-SECRET')));
      }
    });
  });
}
