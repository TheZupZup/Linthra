import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/shared_preferences_playback_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('normalizeVolume preference', () {
    test('in-memory defaults to off and round-trips', () async {
      final prefs = InMemoryPlaybackPreferences();
      expect(await prefs.normalizeVolume(), isFalse);

      await prefs.setNormalizeVolume(true);
      expect(await prefs.normalizeVolume(), isTrue);

      await prefs.setNormalizeVolume(false);
      expect(await prefs.normalizeVolume(), isFalse);
    });

    test('in-memory honours an initial value', () async {
      final prefs = InMemoryPlaybackPreferences(normalizeVolume: true);
      expect(await prefs.normalizeVolume(), isTrue);
    });

    group('shared_preferences', () {
      setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

      test('defaults to off when never set', () async {
        const prefs = SharedPreferencesPlaybackPreferences();
        expect(await prefs.normalizeVolume(), isFalse);
      });

      test('persists the choice across instances', () async {
        const prefs = SharedPreferencesPlaybackPreferences();
        await prefs.setNormalizeVolume(true);

        const reopened = SharedPreferencesPlaybackPreferences();
        expect(await reopened.normalizeVolume(), isTrue);
      });
    });
  });
}
