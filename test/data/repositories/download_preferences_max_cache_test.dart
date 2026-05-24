import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cache_size.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/shared_preferences_download_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('maxCacheBytes preference', () {
    test('in-memory defaults to the sane default and round-trips a value',
        () async {
      final prefs = InMemoryDownloadPreferences();
      expect(await prefs.maxCacheBytes(), CacheSize.defaultLimit);

      await prefs.setMaxCacheBytes(2 * CacheSize.bytesPerGb);
      expect(await prefs.maxCacheBytes(), 2 * CacheSize.bytesPerGb);
    });

    group('shared_preferences', () {
      setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

      test('defaults to the sane default when never set', () async {
        const prefs = SharedPreferencesDownloadPreferences();
        expect(await prefs.maxCacheBytes(), CacheSize.defaultLimit);
      });

      test('persists a chosen limit across instances', () async {
        const prefs = SharedPreferencesDownloadPreferences();
        await prefs.setMaxCacheBytes(8 * CacheSize.bytesPerGb);

        // A fresh instance reads the same persisted value.
        const reopened = SharedPreferencesDownloadPreferences();
        expect(await reopened.maxCacheBytes(), 8 * CacheSize.bytesPerGb);
      });

      test('clamps an out-of-range value into the supported range', () async {
        const prefs = SharedPreferencesDownloadPreferences();
        await prefs.setMaxCacheBytes(1);

        expect(await prefs.maxCacheBytes(), CacheSize.minLimit);
      });
    });
  });
}
