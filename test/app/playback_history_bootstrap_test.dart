import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/models/playback_history.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/playback_history_providers.dart';

import '../support/counting_audio_player.dart';
import '../support/lifecycle_test_graph.dart';
import '../support/recording_media_session.dart';

/// Recent-playback history has to start recording with the *app*, not with the
/// queue pane (#419 follow-up).
///
/// The controller's state stream is a plain broadcast stream: it does not
/// replay, so a recorder created later sees nothing that already happened. The
/// pane starts closed, so a lazily-created recorder meant an empty list at the
/// exact moment the listener opened it to read one.
///
/// This walks the real `bootstrapApplication` graph rather than reading the
/// provider by hand — reading it by hand would pass whether or not bootstrap
/// wires it, which is precisely the bug.
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  /// Bootstrap warms the credential-free remote-cache manifest, which asks
  /// path_provider where the app-support directory is. Answer with a temporary
  /// one so the suite never touches a real user directory.
  setUp(() {
    final Directory temp =
        Directory.systemTemp.createTempSync('linthra-history-bootstrap');
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

  Future<ApplicationHandle> bootstrap(ProviderContainer container) {
    return bootstrapApplication(
      container,
      mediaSessionBinding:
          RecordingMediaSessionBinding(session: RecordingMediaSession()),
    );
  }

  ProviderContainer containerFor(
    CountingAudioPlayer player, {
    HostPlatform host = HostPlatform.linux,
  }) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...linuxLifecycleOverrides(audioPlayer: player),
        hostPlatformProvider.overrideWithValue(host),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('bootstrap creates the recorder before any UI exists', () async {
    final CountingAudioPlayer player = CountingAudioPlayer();
    final ProviderContainer container = containerFor(player);
    final ApplicationHandle handle = await bootstrap(container);
    addTearDown(handle.shutdown);

    // `exists` rather than `read`: reading would *create* the provider and pass
    // whether or not bootstrap wired it, which is exactly the bug this pins.
    // The queue pane has never been built, and the pane is where the provider
    // used to be created.
    expect(
      container.exists(playbackHistoryProvider),
      isTrue,
      reason: 'the recorder must be subscribed before the first frame, or '
          'everything played before the pane is opened is lost',
    );
  });

  test('bootstrap on a touch host still records nothing', () async {
    final CountingAudioPlayer player = CountingAudioPlayer();
    final ProviderContainer container =
        containerFor(player, host: HostPlatform.android);
    final ApplicationHandle handle = await bootstrap(container);
    addTearDown(handle.shutdown);

    expect(container.read(playbackHistoryProvider), PlaybackHistory.empty);
  });
}
