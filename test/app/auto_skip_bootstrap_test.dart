import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../support/counting_audio_player.dart';
import '../support/lifecycle_test_graph.dart';
import '../support/recording_media_session.dart';

/// Preferences whose saved automatic-skip choice takes [read] to come back,
/// like a slow first read at startup.
class _SlowPreferences extends InMemoryPlaybackPreferences {
  _SlowPreferences() : super(autoSkipUnplayable: true);

  final Completer<void> read = Completer<void>();

  @override
  Future<bool?> autoSkipUnplayable() async {
    await read.future;
    return super.autoSkipUnplayable();
  }
}

/// Startup hands the saved "Automatically skip tracks that can't play" to the
/// controller, and must not tell it "off" while that choice is still being
/// read: the controller keeps a failure from that moment for when the choice
/// turns out to be on, and an early "off" would make it a real off.
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final Directory temp =
        Directory.systemTemp.createTempSync('linthra-auto-skip-bootstrap');
    addTearDown(() => temp.deleteSync(recursive: true));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => temp.path,
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );
  });

  test('the saved choice reaches playback only once it has been read',
      () async {
    final _SlowPreferences preferences = _SlowPreferences();
    final ProviderContainer container = ProviderContainer(
      overrides: linuxLifecycleOverrides(
        audioPlayer: CountingAudioPlayer(),
        extra: <Override>[
          playbackPreferencesProvider.overrideWithValue(preferences),
        ],
      ),
    );
    addTearDown(container.dispose);
    final ApplicationHandle handle = await bootstrapApplication(
      container,
      mediaSessionBinding:
          RecordingMediaSessionBinding(session: RecordingMediaSession()),
    );
    addTearDown(handle.shutdown);
    final JustAudioPlaybackController controller = container
        .read(localPlaybackControllerProvider) as JustAudioPlaybackController;

    expect(controller.automaticSkipEnabled, isNull,
        reason: 'still being read: neither on nor a real off yet');

    preferences.read.complete();
    await pumpEventQueue();

    expect(controller.automaticSkipEnabled, isTrue);
  });
}
