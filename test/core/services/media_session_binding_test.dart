import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/core/services/desktop_application_actions.dart';
import 'package:linthra/core/services/media_artwork_source.dart';
import 'package:linthra/core/services/media_session_binding.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';

import '../../features/player/fake_playback_controller.dart';

/// A binding that records whether it was reached at all.
///
/// The point of the platform split is not which value comes back — it is that
/// the Android delegate is never *entered* on a platform where `audio_service`
/// has no implementation, because entering it is what leaves the plugin's
/// statics half-configured.
class _RecordingBinding implements MediaSessionBinding {
  _RecordingBinding({required this.isSupported, required this.result});

  @override
  final bool isSupported;
  final bool result;
  int attachCalls = 0;

  @override
  Future<MediaSession?> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
    DesktopApplicationActions? application,
  }) async {
    attachCalls++;
    return result ? const InertMediaSession() : null;
  }
}

void main() {
  late FakePlaybackController controller;
  late MusicLibraryRepository library;

  setUp(() {
    controller = FakePlaybackController();
    library = InMemoryMusicLibraryRepository();
  });

  tearDown(() async {
    await controller.dispose();
  });

  group('UnsupportedMediaSessionBinding', () {
    test('reports no session and attaches nothing', () async {
      const MediaSessionBinding binding = UnsupportedMediaSessionBinding();

      expect(binding.isSupported, isFalse);
      expect(await binding.attach(controller, library), isNull);
    });
  });

  group('PlatformMediaSessionBinding', () {
    test('on Android, delegates to the audio_service binding', () async {
      final android = _RecordingBinding(isSupported: true, result: true);
      final fallback = _RecordingBinding(isSupported: false, result: false);
      final binding = PlatformMediaSessionBinding(
        host: HostPlatform.android,
        androidBinding: android,
        fallbackBinding: fallback,
      );

      expect(binding.isSupported, isTrue);
      expect(await binding.attach(controller, library), isNotNull);
      expect(android.attachCalls, 1);
      expect(fallback.attachCalls, 0);
    });

    test('on Linux, goes to MPRIS and never enters the Android binding',
        () async {
      final android = _RecordingBinding(isSupported: true, result: true);
      final linux = _RecordingBinding(isSupported: true, result: true);
      final fallback = _RecordingBinding(isSupported: false, result: false);
      final binding = PlatformMediaSessionBinding(
        host: HostPlatform.linux,
        androidBinding: android,
        linuxBinding: linux,
        fallbackBinding: fallback,
      );

      expect(binding.isSupported, isTrue);
      expect(await binding.attach(controller, library), isNotNull);
      expect(android.attachCalls, 0,
          reason: 'audio_service must not initialise on a platform '
              'that has no implementation for it');
      expect(linux.attachCalls, 1);
      expect(fallback.attachCalls, 0);
    });

    test('every platform but Android and Linux routes to the fallback',
        () async {
      for (final HostPlatform host in HostPlatform.values.where(
        (HostPlatform p) =>
            p != HostPlatform.android && p != HostPlatform.linux,
      )) {
        final android = _RecordingBinding(isSupported: true, result: true);
        final linux = _RecordingBinding(isSupported: true, result: true);
        final binding = PlatformMediaSessionBinding(
          host: host,
          androidBinding: android,
          linuxBinding: linux,
          fallbackBinding: _RecordingBinding(isSupported: false, result: false),
        );

        expect(await binding.attach(controller, library), isNull,
            reason: '${host.label} has no media session');
        expect(android.attachCalls, 0,
            reason: 'the Android binding was entered on ${host.label}');
        expect(linux.attachCalls, 0,
            reason: 'MPRIS is a freedesktop interface, not ${host.label}\'s');
      }
    });

    test('the real defaults are the two platforms that have a session', () {
      // No delegate overrides, so this reads the bindings the app itself
      // constructs — without attaching, which on Linux would go looking for a
      // real session bus.
      expect(
        const PlatformMediaSessionBinding(host: HostPlatform.android)
            .isSupported,
        isTrue,
      );
      expect(
        const PlatformMediaSessionBinding(host: HostPlatform.linux).isSupported,
        isTrue,
        reason: 'Linux has MPRIS since #397',
      );
      expect(
        const PlatformMediaSessionBinding(host: HostPlatform.windows)
            .isSupported,
        isFalse,
      );
    });
  });
}
