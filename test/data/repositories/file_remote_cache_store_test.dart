import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';
import 'package:linthra/data/repositories/file_remote_cache_store.dart';
import 'package:path/path.dart' as p;

final DateTime _now = DateTime(2026, 1, 1, 12, 0, 0);

RemoteCacheRecord _record(String uri, {String token = 'SECRET'}) =>
    RemoteCacheRecord.fromEntry(
      RemoteCacheEntry(
        key: RemoteCacheKey.forUri(uri)!,
        streamUri: Uri.parse('https://server.example/stream?api_key=$token'),
        source: PlaybackSource.streamingDirect,
        resolvedAt: _now,
        expiresAt: _now.add(const Duration(minutes: 2)),
      ),
      recordedAt: _now,
      expiresAt: _now.add(const Duration(days: 30)),
    );

void main() {
  group('FileRemoteCacheStore', () {
    late Directory tempDir;
    late FileRemoteCacheStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('linthra_remote_cache');
      store = FileRemoteCacheStore(directory: () async => tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('round-trips records through the on-disk manifest', () async {
      await store.save(<RemoteCacheRecord>[
        _record('jellyfin:a'),
        _record('subsonic:b'),
        _record('plex:1'),
      ]);

      final List<RemoteCacheRecord> loaded = await store.load();

      expect(loaded.map((RemoteCacheRecord r) => r.value),
          <String>['jellyfin:a', 'subsonic:b', 'plex:1']);
      expect(loaded.first.expiresAt, _now.add(const Duration(days: 30)));
    });

    test('the written manifest file carries no token or URL', () async {
      await store.save(<RemoteCacheRecord>[
        _record('plex:101', token: 'SUPER-SECRET'),
      ]);

      final File manifest = File(p.join(tempDir.path, 'index.json'));
      expect(await manifest.exists(), isTrue);
      final String raw = await manifest.readAsString();

      expect(raw, isNot(contains('SUPER-SECRET')));
      expect(raw.toLowerCase(), isNot(contains('token')));
      expect(raw.toLowerCase(), isNot(contains('api_key')));
      expect(raw.toLowerCase(), isNot(contains('http')));
      // It does carry the credential-free key.
      expect(raw, contains('plex:101'));
    });

    test('creates the directory on first save', () async {
      final Directory nested = Directory(p.join(tempDir.path, 'a', 'b', 'c'));
      final FileRemoteCacheStore deepStore =
          FileRemoteCacheStore(directory: () async => nested);

      await deepStore.save(<RemoteCacheRecord>[_record('jellyfin:a')]);

      expect(await nested.exists(), isTrue);
      expect((await deepStore.load()).single.value, 'jellyfin:a');
    });

    test('load on a missing manifest is an empty cold cache', () async {
      expect(await store.load(), isEmpty);
    });

    test('a corrupt manifest degrades to empty (non-fatal)', () async {
      final File manifest = File(p.join(tempDir.path, 'index.json'));
      await manifest.writeAsString('{ this is not json ]');

      expect(await store.load(), isEmpty);
    });

    test('a non-list manifest degrades to empty', () async {
      final File manifest = File(p.join(tempDir.path, 'index.json'));
      await manifest.writeAsString('{"key":"jellyfin:a"}');

      expect(await store.load(), isEmpty);
    });

    test('drops a manifest line whose key smuggled a token', () async {
      // Hand-written manifest: one clean record, one with a tokenized key.
      final File manifest = File(p.join(tempDir.path, 'index.json'));
      await manifest.writeAsString(
        '[{"key":"jellyfin:a","recordedAt":0,"expiresAt":33000000000000},'
        '{"key":"plex:1?X-Plex-Token=SECRET","recordedAt":0,'
        '"expiresAt":33000000000000}]',
      );

      final List<RemoteCacheRecord> loaded = await store.load();

      expect(
          loaded.map((RemoteCacheRecord r) => r.value), <String>['jellyfin:a']);
    });

    test('saving an empty list clears the manifest contents', () async {
      await store.save(<RemoteCacheRecord>[_record('jellyfin:a')]);
      await store.save(const <RemoteCacheRecord>[]);

      expect(await store.load(), isEmpty);
    });

    test('save leaves the manifest in place and no temp file behind', () async {
      await store.save(<RemoteCacheRecord>[_record('jellyfin:a')]);

      expect(await File(p.join(tempDir.path, 'index.json')).exists(), isTrue);
      expect(
        await File(p.join(tempDir.path, 'index.json.tmp')).exists(),
        isFalse,
      );
    });

    test('load ignores a stray temp file left by a torn write', () async {
      // A crash mid-write can leave an index.json.tmp behind; load reads only
      // the committed manifest, so the previous good index survives intact.
      await File(p.join(tempDir.path, 'index.json')).writeAsString(
        '[{"key":"jellyfin:a","recordedAt":0,"expiresAt":33000000000000}]',
      );
      await File(p.join(tempDir.path, 'index.json.tmp'))
          .writeAsString('half-written-garbage');

      expect((await store.load()).single.value, 'jellyfin:a');
    });
  });
}
