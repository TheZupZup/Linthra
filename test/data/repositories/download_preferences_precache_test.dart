import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/shared_preferences_download_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('sanitizePrecacheCount', () {
    test('passes through a named preset', () {
      for (final int option in kPrecacheCountOptions) {
        expect(sanitizePrecacheCount(option), option);
      }
    });

    test('keeps an in-range custom value that is not a preset', () {
      // Anything within the bounds is honoured, presets or not.
      expect(sanitizePrecacheCount(2), 2);
      expect(sanitizePrecacheCount(7), 7);
      expect(sanitizePrecacheCount(42), 42);
      expect(sanitizePrecacheCount(kMinPrecacheCount), kMinPrecacheCount);
      expect(sanitizePrecacheCount(kMaxPrecacheCount), kMaxPrecacheCount);
    });

    test('restores the default for a below-minimum or junk value', () {
      expect(sanitizePrecacheCount(0), kDefaultPrecacheCount);
      expect(sanitizePrecacheCount(-5), kDefaultPrecacheCount);
    });

    test('caps an above-maximum value at the max (never thousands)', () {
      expect(sanitizePrecacheCount(kMaxPrecacheCount + 1), kMaxPrecacheCount);
      expect(sanitizePrecacheCount(9999), kMaxPrecacheCount);
      expect(sanitizePrecacheCount(1000000), kMaxPrecacheCount);
    });
  });

  group('precacheCount preference', () {
    test('in-memory defaults to 3 (unchanged for upgrading users)', () async {
      final prefs = InMemoryDownloadPreferences();
      // Default stays 3 so upgrading users see no behaviour change.
      expect(await prefs.precacheCount(), kDefaultPrecacheCount);
      expect(kDefaultPrecacheCount, 3);
    });

    test('in-memory round-trips the new larger presets (20, 50)', () async {
      final prefs = InMemoryDownloadPreferences();

      await prefs.setPrecacheCount(20);
      expect(await prefs.precacheCount(), 20);

      await prefs.setPrecacheCount(50);
      expect(await prefs.precacheCount(), 50);
    });

    test('in-memory keeps a custom value and clamps an out-of-range one',
        () async {
      final prefs = InMemoryDownloadPreferences(precacheCount: 42);
      expect(await prefs.precacheCount(), 42); // custom, in range → kept

      await prefs.setPrecacheCount(9999);
      expect(await prefs.precacheCount(), kMaxPrecacheCount); // capped at 200

      await prefs.setPrecacheCount(0);
      expect(await prefs.precacheCount(), kDefaultPrecacheCount); // junk → 3
    });

    group('shared_preferences', () {
      setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

      test('defaults to the default when never set', () async {
        const prefs = SharedPreferencesDownloadPreferences();
        expect(await prefs.precacheCount(), kDefaultPrecacheCount);
      });

      test('persists a preset across instances', () async {
        const prefs = SharedPreferencesDownloadPreferences();
        await prefs.setPrecacheCount(20);

        const reopened = SharedPreferencesDownloadPreferences();
        expect(await reopened.precacheCount(), 20);
      });

      test('persists a custom value across instances', () async {
        const prefs = SharedPreferencesDownloadPreferences();
        await prefs.setPrecacheCount(42);

        const reopened = SharedPreferencesDownloadPreferences();
        expect(await reopened.precacheCount(), 42);
      });

      test('caps an above-maximum stored value on read', () async {
        // Simulate a value written far outside the safe range.
        SharedPreferences.setMockInitialValues(<String, Object>{
          'downloads_precache_count': 5000,
        });
        const prefs = SharedPreferencesDownloadPreferences();
        expect(await prefs.precacheCount(), kMaxPrecacheCount);
      });

      test('restores the default for a junk stored value on read', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'downloads_precache_count': 0,
        });
        const prefs = SharedPreferencesDownloadPreferences();
        expect(await prefs.precacheCount(), kDefaultPrecacheCount);
      });
    });
  });
}
