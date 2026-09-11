import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/services/media_session_binding.dart';
import 'package:linthra/core/services/mpris/mpris_media_session.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/favorites_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/remote_cache_index_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/player/lyrics_providers.dart';
import 'package:linthra/features/player/media_artwork_providers.dart';
import 'package:linthra/features/player/playback_history_providers.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../support/fake_audio_player.dart';

/// What `main()` builds before the first frame, on a Linux host.
///
/// `main()` itself cannot be called from a unit test — it runs the app — but the
/// thing that would break a Linux launch is not `runApp`, it is the provider
/// graph constructed above it: one eagerly-built Android-only service is enough
/// to take the process down before a window exists. So this walks that same
/// graph with the host pinned to Linux and asserts every read succeeds.
///
/// It is a smoke test on purpose. It does not assert behaviour of each service —
/// their own suites do that — only that a Linux build can *construct* them.
void main() {
  ProviderContainer linuxContainer() {
    final container = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxAudioPlayerProvider.overrideWithValue(FakeAudioPlayer()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('every provider main() reads before the first frame builds on Linux',
      () {
    final ProviderContainer container = linuxContainer();

    // The order mirrors lib/main.dart.
    expect(() {
      container.read(playbackControllerProvider);
      container.read(musicLibraryRepositoryProvider);
      container.read(playlistRepositoryProvider);
      container.read(favoritesRepositoryProvider);
      container.read(downloadRepositoryProvider);
      container.read(mediaArtworkCacheProvider);
      container.read(mediaArtworkPrewarmServiceProvider);
      container.read(smartPrecacheServiceProvider);
      container.read(remotePrebufferServiceProvider);
      container.read(playbackHistoryProvider);
      container.read(remoteCacheIndexProvider);
      container.read(playbackReportingServiceProvider);
      container.read(remoteControlServiceProvider);
      container.read(remoteControlActivatorProvider);
      container.read(localPlaybackControllerProvider);
      // Linux crash-safe session restore (null on non-Linux).
      container.read(playbackSessionPersistenceProvider);
    }, returnsNormally);
    expect(container.read(playbackSessionPersistenceProvider), isNotNull);
  });

  test('the library and lyrics seams build on Linux too', () {
    final ProviderContainer container = linuxContainer();

    expect(() {
      container.read(audioFileScannerProvider);
      container.read(folderPickerServiceProvider);
      container.read(safDocumentListerProvider);
      container.read(safPermissionProbeProvider);
      container.read(localMetadataReaderProvider);
      container.read(localLyricsReaderProvider);
    }, returnsNormally);
  });

  test('the engine built for Linux is the real Linux controller', () {
    expect(linuxContainer().read(localPlaybackControllerProvider),
        isA<LinuxPlaybackController>());
  });

  test('the volume-normalization listener main() installs is safe to fire', () {
    // main() pushes the persisted "Normalize volume" value onto the local
    // engine immediately. The Linux backend must accept it without throwing
    // before the first frame.
    final ProviderContainer container = linuxContainer();

    expect(
      () => container
          .read(localPlaybackControllerProvider)
          .setVolumeNormalizationEnabled(true),
      returnsNormally,
    );
  });

  test('startup asks for a media session and gets MPRIS, or nothing', () async {
    final ProviderContainer container = linuxContainer();
    // The MPRIS binding with a client factory that fails the way a machine
    // with no session bus does — headless CI, a container, a Flatpak without
    // the socket. Startup must carry on without desktop controls, not fall
    // over, and it must never reach `audio_service` on the way.
    const PlatformMediaSessionBinding binding = PlatformMediaSessionBinding(
      host: HostPlatform.linux,
      linuxBinding: MprisMediaSessionBinding(clientFactory: _noSessionBus),
    );

    expect(binding.isSupported, isTrue,
        reason: 'Linux has a media session since #397');

    final MediaSession? session = await binding.attach(
      container.read(playbackControllerProvider),
      container.read(musicLibraryRepositoryProvider),
      playlists: container.read(playlistRepositoryProvider),
      favorites: container.read(favoritesRepositoryProvider),
      downloads: container.read(downloadRepositoryProvider),
      artwork: container.read(mediaArtworkCacheProvider),
    );

    expect(session, isNull);
  });
}

/// A [DBusClient] factory that fails like a host with no session bus.
DBusClient _noSessionBus() => throw const SocketException('no session bus');
