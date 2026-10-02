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

  group('autoSkipUnplayable preference', () {
    test('in-memory starts unchosen and round-trips', () async {
      final prefs = InMemoryPlaybackPreferences();
      expect(await prefs.autoSkipUnplayable(), isNull);

      await prefs.setAutoSkipUnplayable(true);
      expect(await prefs.autoSkipUnplayable(), isTrue);

      await prefs.setAutoSkipUnplayable(false);
      expect(await prefs.autoSkipUnplayable(), isFalse);
    });

    group('shared_preferences', () {
      setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

      test('is unchosen until the listener answers', () async {
        const prefs = SharedPreferencesPlaybackPreferences();
        expect(await prefs.autoSkipUnplayable(), isNull,
            reason: 'unchosen is what lets the player ask, once');
      });

      test('persists either answer across instances', () async {
        for (final bool answer in <bool>[true, false]) {
          await const SharedPreferencesPlaybackPreferences()
              .setAutoSkipUnplayable(answer);
          expect(
            await const SharedPreferencesPlaybackPreferences()
                .autoSkipUnplayable(),
            answer,
          );
        }
      });

      test('a value of the wrong type reads as unchosen, not a crash',
          () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'playback_auto_skip_unplayable': 'yes',
        });
        expect(
          await const SharedPreferencesPlaybackPreferences()
              .autoSkipUnplayable(),
          isNull,
        );
      });
    });
  });
}
