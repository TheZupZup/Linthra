import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/playback_candidates_provider.dart';
import 'package:linthra/features/library/source_preference_controller.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_availability_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../support/counting_audio_player.dart';
import '../../support/fake_local_file_presence.dart';

// The same songs on a home Jellyfin server and on this device. Jellyfin is the
// preferred copy (signing in makes it so), so that is what a queue holds. Then
// the listener walks away from the server's network while the queue plays.

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'http://192.168.22.1:8096',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
);

Track _jellyfin(String id, String title) => Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
    );

Track _local(String id, String title) => Track(
      id: '/music/Adele/25/$id.flac',
      title: title,
      uri: '/music/Adele/25/$id.flac',
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
    );

/// An engine that remembers every source it was handed.
class _RecordingPlayer extends CountingAudioPlayer {
  final List<String> opened = <String>[];

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) {
    opened.add(url);
    return super.setUrl(url);
  }
}

class _JellyfinFirst extends SourcePreferenceController {
  @override
  SourcePriority build() => const SourcePriority(<String>['jellyfin']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'a queued song from a server that can no longer be reached plays from '
      'its copy on this device', () async {
    final List<Track> jellyfin = <Track>[
      _jellyfin('1', 'Hello'),
      _jellyfin('2', 'Send My Love'),
      _jellyfin('3', 'When We Were Young'),
    ];
    final List<Track> local = <Track>[
      _local('1', 'Hello'),
      _local('2', 'Send My Love'),
      _local('3', 'When We Were Young'),
    ];
    final InMemoryMusicLibraryRepository repository =
        InMemoryMusicLibraryRepository();
    await repository.upsertCatalog(
      sourceId: 'jellyfin',
      tracks: jellyfin,
      albums: groupAlbums(jellyfin),
      artists: groupArtists(jellyfin),
    );
    await repository.upsertCatalog(
      sourceId: 'local',
      tracks: local,
      albums: groupAlbums(local),
      artists: groupArtists(local),
    );
    final FakeJellyfinClient client = FakeJellyfinClient();
    final _RecordingPlayer player = _RecordingPlayer();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxAudioPlayerProvider.overrideWithValue(player),
        localFilePresenceProvider
            .overrideWithValue(FakeLocalFilePresence.all()),
        musicLibraryRepositoryProvider.overrideWithValue(repository),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _session),
        ),
        jellyfinClientProvider.overrideWithValue(client),
        librarySourcePriorityProvider.overrideWith(_JellyfinFirst.new),
        jellyfinAvailabilityPollIntervalProvider.overrideWithValue(null),
        // The production candidate source, reading the live library.
        playbackCandidateSourceOverride,
        // Without automatic retries and skips the outcome of each track is
        // the controller's own first answer.
        playbackRecoveryPolicyProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    container.listen(jellyfinAvailabilityProvider, (_, __) {});
    container.listen(libraryControllerProvider, (_, __) {});
    await container
        .read(jellyfinSettingsControllerProvider.notifier)
        .ensureLoaded();
    await container.read(jellyfinAvailabilityProvider.notifier).refresh();
    await container.read(libraryControllerProvider.notifier).refresh();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);

    final PlaybackController playback =
        container.read(playbackControllerProvider);
    await playback.playTracks(jellyfin);
    expect(playback.state.currentTrack?.uri, 'jellyfin:1');

    // Away from home: the server stops answering.
    client.verifyError = JellyfinException.notReachable();

    // The next song tries the server, can't reach it, and falls back to the
    // copy on this device. That failure also tells the library the server is
    // unreachable.
    await playback.skipToNext();
    expect(playback.state.status, isNot(PlaybackStatus.error));
    expect(playback.state.currentTrack?.uri, local[1].uri);
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.unreachable);

    // The song after it is on this device too, and must play from there.
    await playback.skipToNext();
    expect(playback.state.failure?.message, isNull,
        reason: 'the song has a copy on this device');
    expect(playback.state.currentTrack?.uri, local[2].uri);
    expect(player.opened.last, Uri.file(local[2].uri).toString());
  });
}
