import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_stream_quality.dart';
import 'package:linthra/core/services/audio_quality_probe.dart';
import 'package:linthra/data/repositories/audio_quality_probe_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/auto_skip_controller.dart';
import 'package:linthra/features/settings/playback/normalize_volume_controller.dart';
import 'package:linthra/features/settings/playback/playback_settings_section.dart';
import 'package:linthra/features/settings/playback/show_audio_quality_controller.dart';

/// A probe for an engine that can report, so the setting is offered.
class _ReadableEngine implements AudioQualityProbe {
  const _ReadableEngine();

  @override
  bool get isAvailable => true;

  @override
  AudioStreamQuality? current() => null;

  @override
  Stream<void> changes() => const Stream<void>.empty();
}

void main() {
  group('PlaybackSettingsSection', () {
    late InMemoryPlaybackPreferences preferences;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      bool normalizeVolume = false,
      bool? autoSkip,
      bool showAudioQuality = false,
      bool engineReportsQuality = false,
    }) async {
      preferences = InMemoryPlaybackPreferences(
        normalizeVolume: normalizeVolume,
        autoSkipUnplayable: autoSkip,
        showAudioQuality: showAudioQuality,
      );
      final container = ProviderContainer(
        overrides: [
          playbackPreferencesProvider.overrideWithValue(preferences),
          if (engineReportsQuality)
            audioQualityProbeProvider
                .overrideWithValue(const _ReadableEngine()),
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
      final SwitchListTile tile = tester.widget(
        find.widgetWithText(SwitchListTile, 'Normalize volume'),
      );
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

    testWidgets('offers automatic skip, off until the listener allows it',
        (tester) async {
      await pump(tester);

      final Finder tile = find.widgetWithText(
        SwitchListTile,
        "Automatically skip tracks that can't play",
      );
      expect(tile, findsOneWidget);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(
        find.textContaining('After Linthra finishes its recovery attempts'),
        findsOneWidget,
      );
    });

    testWidgets('the switch writes the same preference the player reads',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      await tester.tap(find.text("Automatically skip tracks that can't play"));
      await tester.pumpAndSettle();
      expect(await preferences.autoSkipUnplayable(), isTrue);
      expect(container.read(autoSkipControllerProvider).valueOrNull, isTrue);

      await tester.tap(find.text("Automatically skip tracks that can't play"));
      await tester.pumpAndSettle();
      expect(await preferences.autoSkipUnplayable(), isFalse);
    });

    testWidgets('shows a saved choice', (tester) async {
      await pump(tester, autoSkip: true);
      final SwitchListTile tile = tester.widget(
        find.widgetWithText(
          SwitchListTile,
          "Automatically skip tracks that can't play",
        ),
      );
      expect(tile.value, isTrue);
    });

    testWidgets('does not offer audio quality where the engine cannot report',
        (tester) async {
      await pump(tester);
      expect(find.text('Show audio quality'), findsNothing);
    });

    testWidgets('offers audio quality off by default', (tester) async {
      await pump(tester, engineReportsQuality: true);
      final SwitchListTile tile = tester.widget(
        find.widgetWithText(SwitchListTile, 'Show audio quality'),
      );
      expect(tile.value, isFalse);
    });

    testWidgets('the audio quality switch persists both ways', (tester) async {
      final ProviderContainer container =
          await pump(tester, engineReportsQuality: true);

      await tester.tap(find.text('Show audio quality'));
      await tester.pumpAndSettle();
      expect(await preferences.showAudioQuality(), isTrue);
      expect(
        container.read(showAudioQualityControllerProvider).valueOrNull,
        isTrue,
      );

      await tester.tap(find.text('Show audio quality'));
      await tester.pumpAndSettle();
      expect(await preferences.showAudioQuality(), isFalse);
    });

    testWidgets('shows a saved audio quality choice', (tester) async {
      await pump(tester, engineReportsQuality: true, showAudioQuality: true);
      final SwitchListTile tile = tester.widget(
        find.widgetWithText(SwitchListTile, 'Show audio quality'),
      );
      expect(tile.value, isTrue);
    });
  });
}
