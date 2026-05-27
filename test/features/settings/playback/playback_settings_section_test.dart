import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/normalize_volume_controller.dart';
import 'package:linthra/features/settings/playback/playback_settings_section.dart';

void main() {
  group('PlaybackSettingsSection', () {
    late InMemoryPlaybackPreferences preferences;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      bool normalizeVolume = false,
    }) async {
      preferences =
          InMemoryPlaybackPreferences(normalizeVolume: normalizeVolume);
      final container = ProviderContainer(
        overrides: [
          playbackPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: PlaybackSettingsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('shows the playback copy and the normalize switch',
        (tester) async {
      await pump(tester);

      expect(find.text('Playback'), findsOneWidget);
      expect(find.text('Normalize volume'), findsOneWidget);
      expect(find.textContaining('ReplayGain'), findsWidgets);
    });

    testWidgets('defaults off', (tester) async {
      await pump(tester);
      final SwitchListTile tile = tester.widget(find.byType(SwitchListTile));
      expect(tile.value, isFalse);
    });

    testWidgets('toggling on persists the choice', (tester) async {
      final container = await pump(tester);
      expect(await preferences.normalizeVolume(), isFalse);

      await tester.tap(find.text('Normalize volume'));
      await tester.pumpAndSettle();

      expect(await preferences.normalizeVolume(), isTrue);
      expect(
        container.read(normalizeVolumeControllerProvider).valueOrNull,
        isTrue,
      );
    });

    testWidgets('toggling off persists the choice', (tester) async {
      final container = await pump(tester, normalizeVolume: true);
      expect(await preferences.normalizeVolume(), isTrue);

      await tester.tap(find.text('Normalize volume'));
      await tester.pumpAndSettle();

      expect(await preferences.normalizeVolume(), isFalse);
      expect(
        container.read(normalizeVolumeControllerProvider).valueOrNull,
        isFalse,
      );
    });
  });
}
