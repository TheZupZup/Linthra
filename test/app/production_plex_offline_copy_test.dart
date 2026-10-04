import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_container.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/theme_mode_preference.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/offline_first_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/data/repositories/default_provider_store_provider.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_default_provider_store.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/in_memory_preferred_source_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/data/repositories/preferred_source_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/sources/plex/fake_plex_client.dart';

/// A Plex song kept offline on one server, after connecting to another,
/// walked through the app's real production override list. Only the edges
/// are replaced: the Plex server, the keyring, the catalog database, the
/// preference stores, the network, the files on disk and the audio engine.
///
/// A Plex track is `plex:<ratingKey>` everywhere Linthra stores it, and a
/// ratingKey only means something on the server that issued it. Connecting
/// to another server drops the old catalog rows, but an offline copy keyed by
/// the same `plex` and ratingKey used to stand in for the new server's song
/// with that number: it read as downloaded and played the old server's audio.

const PlexSession _home = PlexSession(
  baseUrl: 'https://home.example.com:32400',
  token: 'token-home',
  machineIdentifier: 'machine-home',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

const PlexDirectory _music =
    PlexDirectory(key: '5', title: 'Music', type: 'artist');

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// The bytes it returns are the audio of whichever server is connected.
class _PlexDownloader implements RemoteTrackDownloader {
  List<int> serverAudio = <int>[0xA, 0xA, 0xA, 0xA];

  @override
  bool isRemote(Track track) => track.uri.startsWith('plex:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      RemoteTrackData(bytes: serverAudio, fileExtension: 'flac');
}

class _Stream implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async => ResolvedPlayable(
        Uri.parse('https://plex.example/stream/${track.id}'),
        PlaybackSource.streamingDirect,
      );
}

void main() {
  // The settings stores the production list wires read the platform's
  // preferences; an empty in-memory set stands in for a fresh install.
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  ProviderContainer production(
    FakePlexClient client,
    _PlexDownloader downloader,
  ) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...productionApplicationOverrides(
          storedThemeMode: ThemeModePreference.system,
          host: HostPlatform.android,
        ),
        // The edges; a later override of a provider replaces the earlier one.
        plexClientProvider.overrideWithValue(client),
        plexSessionStoreProvider
            .overrideWithValue(InMemoryPlexSessionStore(initialSession: _home)),
        musicLibraryRepositoryProvider
            .overrideWithValue(InMemoryMusicLibraryRepository()),
        preferredSourceStoreProvider
            .overrideWithValue(InMemoryPreferredSourceStore()),
        defaultProviderStoreProvider
            .overrideWithValue(InMemoryDefaultProviderStore()),
        remoteTrackDownloaderProvider.overrideWithValue(downloader),
        connectivityServiceProvider.overrideWithValue(_Wifi()),
        offlineFileStoreProvider.overrideWithValue(InMemoryOfflineFileStore()),
        downloadStoreProvider.overrideWithValue(InMemoryDownloadStore()),
        currentlyPlayingTrackProvider.overrideWithValue(() => null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  FakePlexClient friendServer() => FakePlexClient(
        // The server connected next identifies as another machine.
        identity: const PlexServerIdentity(machineIdentifier: 'machine-friend'),
        sections: const <PlexDirectory>[_music],
      );

  Future<ResolvedPlayable> resolve(ProviderContainer container, Track track) =>
      OfflineFirstPlayableUriResolver(
        locator: container.read(cachedTrackLocatorProvider),
        fallback: _Stream(),
      ).resolve(track);

  test(
      "after connecting to another Plex server, the previous server's download "
      "is not served or shown for the new server's song with the same "
      'ratingKey', () async {
    final _PlexDownloader downloader = _PlexDownloader();
    final ProviderContainer container = production(friendServer(), downloader);
    final PlexSettingsController plex =
        container.read(plexSettingsControllerProvider.notifier);
    await plex.ensureLoaded();
    expect(plex.session!.machineIdentifier, 'machine-home');

    // On the home server, the listener downloads its ratingKey 101.
    const Track homeSong =
        Track(id: '101', title: 'Song on home', uri: 'plex:101');
    final DownloadRepository downloads =
        container.read(downloadRepositoryProvider);
    expect(await downloads.requestDownload(homeSong),
        DownloadRequestOutcome.started);
    expect(await downloads.statusFor('101'), DownloadStatus.downloaded);

    // Settings, Plex: the listener connects to a friend's server instead.
    downloader.serverAudio = <int>[0xF, 0xF, 0xF, 0xF];
    expect(
      await plex.connect(
          url: 'https://friend.example.com:32400', token: 'token-f'),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(plex.session!.machineIdentifier, 'machine-friend');

    // The friend's library has its own ratingKey 101: a different song.
    const Track friendSong =
        Track(id: '101', title: 'Song on friend', uri: 'plex:101');
    expect(
      (await downloads
          .statusStream.first)[CachedTrack.cacheKeyForTrack(friendSong)],
      isNull,
      reason: "the friend's song reads as downloaded",
    );
    expect(
      await container.read(cachedTrackLocatorProvider).cachedFilePath(
            friendSong,
          ),
      isNull,
      reason: "the home server's audio is served for the friend's song",
    );
    expect((await resolve(container, friendSong)).source,
        PlaybackSource.streamingDirect);
  });

  test(
      "after Disconnect and another server, the previous server's pre-cached "
      "copy is not played for the new server's song", () async {
    final _PlexDownloader downloader = _PlexDownloader();
    final ProviderContainer container = production(friendServer(), downloader);
    final PlexSettingsController plex =
        container.read(plexSettingsControllerProvider.notifier);
    await plex.ensureLoaded();

    // Smart pre-cache warmed the home server's ratingKey 202 ahead of play.
    await container
        .read(trackPrefetcherProvider)
        .prefetch(const Track(id: '202', title: 'home', uri: 'plex:202'));
    expect(
      (await container.read(offlineCacheManagerProvider).cacheSnapshot())
          .entries
          .single
          .preloaded,
      isTrue,
    );

    await plex.disconnect();
    expect(
      await plex.connect(
          url: 'https://friend.example.com:32400', token: 'token-f'),
      isTrue,
    );
    expect(plex.session!.machineIdentifier, 'machine-friend');

    const Track friendSong =
        Track(id: '202', title: 'Song on friend', uri: 'plex:202');
    expect(
      (await resolve(container, friendSong)).source,
      PlaybackSource.streamingDirect,
      reason: "the home server's pre-cached audio plays for the friend's song",
    );
  });
}
