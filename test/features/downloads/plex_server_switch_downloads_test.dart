import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
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
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/in_memory_preferred_source_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/data/repositories/preferred_source_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';

import '../../core/sources/plex/fake_plex_client.dart';

// A Plex ratingKey is a number its server hands out, and a Plex track is
// `plex:<ratingKey>` everywhere Linthra stores it. Connecting to another
// server drops the old server's catalog rows, but the offline cache, keyed by
// the same `plex` + ratingKey, kept the old server's copies: the new server's
// song with that number read as downloaded and played the old server's audio.
// These run the real settings controller, download repository and locator
// with the app's own bindings.

const PlexSession _home = PlexSession(
  baseUrl: 'https://home.example.com:32400',
  token: 'token-a',
  machineIdentifier: 'machine-home',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

const PlexServerIdentity _homeIdentity =
    PlexServerIdentity(machineIdentifier: 'machine-home');
const PlexServerIdentity _friendIdentity =
    PlexServerIdentity(machineIdentifier: 'machine-friend');

const PlexDirectory _music =
    PlexDirectory(key: '5', title: 'Music', type: 'artist');

const List<int> _homeAudio = <int>[0xA, 0xA, 0xA, 0xA];
const List<int> _friendAudio = <int>[0xF, 0xF, 0xF, 0xF];

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Stands in for the live Plex downloader, which fetches through whichever
/// server is connected when it runs: the bytes are that server's audio.
class _PlexDownloader implements RemoteTrackDownloader {
  _PlexDownloader(this._connectedServer);

  final String? Function() _connectedServer;

  @override
  bool isRemote(Track track) => track.uri.startsWith('plex:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final String? server = _connectedServer();
    if (server == null) throw StateError('Not signed in to your Plex server.');
    return RemoteTrackData(
      bytes: server == 'machine-home' ? _homeAudio : _friendAudio,
      fileExtension: 'flac',
    );
  }
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

Track _song(String ratingKey, String title) =>
    Track(id: ratingKey, title: title, uri: 'plex:$ratingKey');

void main() {
  late FakePlexClient client;
  late InMemoryOfflineFileStore files;
  late ProviderContainer container;
  late PlexSettingsController plex;

  setUp(() async {
    client = FakePlexClient(sections: const <PlexDirectory>[_music]);
    files = InMemoryOfflineFileStore();
    container = ProviderContainer(
      overrides: <Override>[
        plexClientProvider.overrideWithValue(client),
        plexSessionStoreProvider
            .overrideWithValue(InMemoryPlexSessionStore(initialSession: _home)),
        musicLibraryRepositoryProvider
            .overrideWithValue(InMemoryMusicLibraryRepository()),
        preferredSourceStoreProvider
            .overrideWithValue(InMemoryPreferredSourceStore()),
        defaultProviderStoreProvider
            .overrideWithValue(InMemoryDefaultProviderStore()),
        remoteTrackDownloaderProvider.overrideWith(
          (ref) => _PlexDownloader(() =>
              ref.read(plexMusicSourceProvider)?.session.machineIdentifier),
        ),
        connectivityServiceProvider.overrideWithValue(_Wifi()),
        offlineFileStoreProvider.overrideWithValue(files),
        // The app's own bindings.
        downloadAccountScopeOverride,
        offlineCopyOriginsOverride,
      ],
    );
    plex = container.read(plexSettingsControllerProvider.notifier);
    await plex.ensureLoaded();
    expect(plex.session!.machineIdentifier, 'machine-home');
  });

  tearDown(() => container.dispose());

  DownloadRepository downloads() => container.read(downloadRepositoryProvider);

  Future<void> settle() async {
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Settings -> Plex: connect to [identity]'s server instead.
  Future<void> connectTo(PlexServerIdentity identity, String url) async {
    client.identity = identity;
    expect(await plex.connect(url: url, token: 'token-$url'), isTrue);
    await settle();
    expect(plex.session!.machineIdentifier, identity.machineIdentifier);
  }

  Future<DownloadStatus?> rowOf(Track track) async => (await downloads()
      .statusStream
      .first)[CachedTrack.cacheKeyForTrack(track)];

  Future<ResolvedPlayable> play(Track track) => OfflineFirstPlayableUriResolver(
        locator: container.read(cachedTrackLocatorProvider),
        fallback: _Stream(),
      ).resolve(track);

  Future<List<int>?> offlineBytes(Track track) async {
    final String? path =
        await container.read(cachedTrackLocatorProvider).cachedFilePath(track);
    return path == null ? null : files.bytesFor(path.split('/').last);
  }

  test(
      "after connecting to another Plex server, the previous server's offline "
      "copy is not served for the new server's song with the same ratingKey",
      () async {
    expect(await downloads().requestDownload(_song('101', 'Song on home')),
        DownloadRequestOutcome.started);
    expect(await downloads().statusFor('101'), DownloadStatus.downloaded);

    await connectTo(_friendIdentity, 'https://friend.example.com:32400');

    // Never downloaded on this server: its row must not read "Downloaded",
    // and it must stream rather than play the home server's song 101.
    final Track friendSong = _song('101', 'Song on friend');
    expect(await rowOf(friendSong), isNull,
        reason: "the friend's song reads as downloaded");
    expect(await offlineBytes(friendSong), isNull,
        reason: "the home server's audio is served for the friend's song");
    expect((await play(friendSong)).source, PlaybackSource.streamingDirect);
  });

  test(
      'the same after Disconnect, then connecting to another server (a '
      'pre-cached copy this time)', () async {
    // Smart pre-cache warmed the home server's ratingKey 202 ahead of play.
    await container
        .read(trackPrefetcherProvider)
        .prefetch(_song('202', 'Song on home'));
    expect(
        (await container.read(offlineCacheManagerProvider).cacheSnapshot())
            .entries
            .single
            .preloaded,
        isTrue);

    await plex.disconnect();
    await settle();
    await connectTo(_friendIdentity, 'https://friend.example.com:32400');

    expect((await play(_song('202', 'Song on friend'))).source,
        PlaybackSource.streamingDirect,
        reason: "the home server's pre-cached audio plays for the friend's "
            'song');
  });

  test('the copy comes back when its own server is connected again', () async {
    final Track homeSong = _song('101', 'Song on home');
    await downloads().requestDownload(homeSong);
    await connectTo(_friendIdentity, 'https://friend.example.com:32400');
    expect(await rowOf(homeSong), isNull);

    await connectTo(_homeIdentity, 'https://home.example.com:32400');

    expect(await rowOf(homeSong), DownloadStatus.downloaded);
    expect((await play(homeSong)).source, PlaybackSource.offlineCache);
    expect(await offlineBytes(homeSong), _homeAudio);
  });

  test("each server's copy of the same ratingKey is kept apart", () async {
    await downloads().requestDownload(_song('101', 'Song on home'));
    await connectTo(_friendIdentity, 'https://friend.example.com:32400');
    // The friend's own song 101, downloaded while the home copy is kept.
    await downloads().requestDownload(_song('101', 'Song on friend'));
    expect(await offlineBytes(_song('101', 'Song on friend')), _friendAudio);

    await connectTo(_homeIdentity, 'https://home.example.com:32400');
    expect(await offlineBytes(_song('101', 'Song on home')), _homeAudio,
        reason: "the friend's copy was written over the home server's file");

    await connectTo(_friendIdentity, 'https://friend.example.com:32400');
    expect(await offlineBytes(_song('101', 'Song on friend')), _friendAudio);
  });

  test('reconnecting to the same server keeps its copies in use', () async {
    // A new token for the same server (Reconnect with Plex, or another Home
    // profile on it): ratingKeys still name the same songs there.
    final Track homeSong = _song('101', 'Song on home');
    await downloads().requestDownload(homeSong);

    await connectTo(_homeIdentity, 'https://home.example.com:32400');

    expect(await rowOf(homeSong), DownloadStatus.downloaded);
    expect(await offlineBytes(homeSong), _homeAudio);
  });
}
