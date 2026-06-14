import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_record.dart';

const String _token = 'SUPER-SECRET-TOKEN';

/// A live, in-memory entry whose stream URL carries a token — exactly the thing
/// that must never reach the persisted record built from it.
RemoteCacheEntry _entry(
  String uri, {
  required DateTime now,
  String token = _token,
}) =>
    RemoteCacheEntry(
      key: RemoteCacheKey.forUri(uri)!,
      streamUri: Uri.parse('https://server.example/stream?api_key=$token'),
      source: PlaybackSource.streamingDirect,
      resolvedAt: now,
      expiresAt: now.add(const Duration(minutes: 2)),
    );

void main() {
  final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
  final DateTime expires = now.add(const Duration(days: 30));

  group('RemoteCacheRecord.fromEntry', () {
    test('routes Jellyfin, Subsonic and Plex by their credential-free key', () {
      for (final MapEntry<String, String> sample in <String, String>{
        'jellyfin:abc': 'jellyfin',
        'subsonic:def': 'subsonic',
        'plex:101': 'plex',
      }.entries) {
        final RemoteCacheRecord record = RemoteCacheRecord.fromEntry(
          _entry(sample.key, now: now),
          recordedAt: now,
          expiresAt: expires,
        );
        expect(record.value, sample.key);
        expect(record.sourceId, sample.value);
        expect(record.fileSafeName, startsWith('${sample.value}_'));
      }
    });

    test('copies only the credential-free key — never the stream URL', () {
      final RemoteCacheEntry entry = _entry('plex:101', now: now);
      final RemoteCacheRecord record = RemoteCacheRecord.fromEntry(
        entry,
        recordedAt: now,
        expiresAt: expires,
      );

      // The token lives on the entry's in-memory stream URL (allowed) ...
      expect(entry.streamUri.toString(), contains(_token));
      // ... but nowhere on the record or its serialized / loggable surfaces.
      final String encoded = jsonEncode(record.toJson());
      for (final String surface in <String>[
        record.value,
        record.sourceId,
        record.fileSafeName,
        record.toString(),
        encoded,
      ]) {
        expect(surface, isNot(contains(_token)));
        expect(surface.toLowerCase(), isNot(contains('token')));
        expect(surface.toLowerCase(), isNot(contains('api_key')));
        expect(surface.toLowerCase(), isNot(contains('http')));
      }
    });

    test('the JSON has only the opaque key and timestamps — no URL field', () {
      final Map<String, dynamic> json = RemoteCacheRecord.fromEntry(
              _entry('jellyfin:abc', now: now),
              recordedAt: now,
              expiresAt: expires)
          .toJson();

      expect(json.keys.toSet(), <String>{'key', 'recordedAt', 'expiresAt'});
      expect(json['key'], 'jellyfin:abc');
      expect(json['recordedAt'], now.millisecondsSinceEpoch);
      expect(json['expiresAt'], expires.millisecondsSinceEpoch);
    });
  });

  group('RemoteCacheRecord JSON round-trip', () {
    test('toJson then fromJson reproduces the record', () {
      final RemoteCacheRecord original = RemoteCacheRecord.fromEntry(
        _entry('subsonic:xyz', now: now),
        recordedAt: now,
        expiresAt: expires,
      );

      final RemoteCacheRecord? restored =
          RemoteCacheRecord.fromJson(original.toJson());

      expect(restored, isNotNull);
      expect(restored, original);
      expect(restored!.value, 'subsonic:xyz');
      expect(restored.expiresAt, expires);
    });

    test('a restored record carries no stream URL — forcing a fresh resolve',
        () {
      // The persisted form has nowhere to keep a URL, so after a "restart"
      // (load from JSON) there is nothing stale to replay: only the key remains.
      final RemoteCacheRecord restored = RemoteCacheRecord.fromJson(
        RemoteCacheRecord.fromEntry(_entry('plex:101', now: now),
                recordedAt: now, expiresAt: expires)
            .toJson(),
      )!;
      expect(jsonEncode(restored.toJson()), isNot(contains('server.example')));
      expect(restored.value, 'plex:101');
    });
  });

  group('RemoteCacheRecord.fromJson defends the credential-free boundary', () {
    test('drops a missing or empty key', () {
      expect(RemoteCacheRecord.fromJson(<String, dynamic>{}), isNull);
      expect(
        RemoteCacheRecord.fromJson(<String, dynamic>{'key': ''}),
        isNull,
      );
    });

    test('drops a tampered, tokenized key (cannot be reintroduced via JSON)',
        () {
      // A hand-edited manifest line that smuggled a token must not load.
      expect(
        RemoteCacheRecord.fromJson(<String, dynamic>{
          'key': 'plex:101?X-Plex-Token=SECRET',
          'recordedAt': now.millisecondsSinceEpoch,
          'expiresAt': expires.millisecondsSinceEpoch,
        }),
        isNull,
      );
    });

    test('drops a local or content:// key (not a remote stream)', () {
      expect(
        RemoteCacheRecord.fromJson(<String, dynamic>{'key': 'file:///a.mp3'}),
        isNull,
      );
      expect(
        RemoteCacheRecord.fromJson(
          <String, dynamic>{'key': 'content://media/audio/1'},
        ),
        isNull,
      );
    });

    test('tolerates missing/malformed timestamps (treated as long expired)',
        () {
      final RemoteCacheRecord? record = RemoteCacheRecord.fromJson(
        <String, dynamic>{'key': 'jellyfin:abc'},
      );
      expect(record, isNotNull);
      // No usable expiry -> epoch -> stale now, so the sweep drops it.
      expect(record!.isFresh(now), isFalse);
    });
  });

  group('RemoteCacheRecord freshness', () {
    test('is fresh before expiry and stale after', () {
      final RemoteCacheRecord record = RemoteCacheRecord.fromEntry(
        _entry('jellyfin:abc', now: now),
        recordedAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      );
      expect(record.isFresh(now), isTrue);
      expect(record.isFresh(now.add(const Duration(hours: 23))), isTrue);
      expect(record.isFresh(now.add(const Duration(days: 1))), isFalse);
      expect(record.isFresh(now.add(const Duration(days: 2))), isFalse);
    });
  });
}
