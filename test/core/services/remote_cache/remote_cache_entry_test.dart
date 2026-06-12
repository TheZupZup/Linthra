import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_entry.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';

RemoteCacheEntry _entry({
  required DateTime resolvedAt,
  required DateTime expiresAt,
  String uri = 'https://server.example/stream?api_key=SECRET-TOKEN',
}) =>
    RemoteCacheEntry(
      key: RemoteCacheKey.forUri('plex:101')!,
      streamUri: Uri.parse(uri),
      source: PlaybackSource.streamingDirect,
      resolvedAt: resolvedAt,
      expiresAt: expiresAt,
    );

void main() {
  group('RemoteCacheEntry', () {
    final DateTime start = DateTime(2026, 1, 1, 12, 0, 0);

    test('is fresh before it expires and stale after', () {
      final RemoteCacheEntry entry = _entry(
        resolvedAt: start,
        expiresAt: start.add(const Duration(minutes: 2)),
      );

      expect(entry.isFresh(start), isTrue);
      expect(entry.isFresh(start.add(const Duration(minutes: 1))), isTrue);
      // At/after the expiry it is stale (so a possibly-expired URL is dropped).
      expect(entry.isFresh(start.add(const Duration(minutes: 2))), isFalse);
      expect(entry.isFresh(start.add(const Duration(minutes: 5))), isFalse);
    });

    test('diagnosticLabel is credential-free and omits the stream URL', () {
      final RemoteCacheEntry entry = _entry(
        resolvedAt: start,
        expiresAt: start.add(const Duration(minutes: 2)),
      );

      final String label = entry.diagnosticLabel.toLowerCase();
      expect(label, isNot(contains('secret')));
      expect(label, isNot(contains('token')));
      expect(label, isNot(contains('api_key')));
      expect(label, isNot(contains('https')));
      // It does carry the safe metadata, so it is still useful.
      expect(entry.diagnosticLabel, contains('plex:101'));
    });
  });
}
