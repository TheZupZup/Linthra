import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/offline_first_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/data/repositories/default_provider_store_provider.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_default_provider_store.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/in_memory_preferred_source_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/preferred_source_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';

import '../../core/sources/subsonic/fake_subsonic_client.dart';

// Most Subsonic servers number their songs (Airsonic, Ampache, gonic's
// `tr-N`), and a Subsonic track is `subsonic:<id>` everywhere Linthra stores
// it. Signing in to another server clears the old catalog rows (#741), but the
// offline cache, keyed by the same `subsonic` + id, kept the old server's
// copies: the new server's song with that id read as downloaded and played the
// old server's audio (#738). Navidrome derives its ids from file paths, which
// another installation can share for another file, so its copies are bound
// the same way. These run the real settings controller, download repository
// and locator with the app's own bindings.

const String _airsonicA = 'https://a.example.com';
const String _airsonicB = 'https://b.example.com';
const String _navidromeLan = 'http://192.168.1.10:4533';
const String _navidromeProxy = 'https://music.example.com';

/// A classic Subsonic server: no OpenSubsonic `type`.
const SubsonicServerInfo _airsonic = SubsonicServerInfo(apiVersion: '1.15.0');
const SubsonicServerInfo _navidrome = SubsonicServerInfo(
  apiVersion: '1.16.1',
  type: 'navidrome',
  serverVersion: '0.53.3',
);

const SubsonicSession _signedInToA = SubsonicSession(
  baseUrl: _airsonicA,
  username: 'alice',
  salt: 'salt-a',
  token: 'token-a',
);

const List<int> _audioOfA = <int>[0xA, 0xA, 0xA, 0xA];
const List<int> _audioOfB = <int>[0xB, 0xB, 0xB, 0xB];
const List<int> _audioOfNavidrome = <int>[0xD, 0xD, 0xD, 0xD];

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Stands in for the live Subsonic downloader, which fetches through whichever
/// server is signed in when it runs: the bytes are that server's audio.
class _SubsonicDownloader implements RemoteTrackDownloader {
  _SubsonicDownloader(this._signedInTo);

  final String? Function() _signedInTo;

  /// When set, a fetch that has started (and so knows its server) waits for
  /// it before its bytes arrive.
  Completer<void>? gate;

  @override
  bool isRemote(Track track) => track.uri.startsWith('subsonic:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final String? server = _signedInTo();
    if (server == null) throw StateError('Not signed in to Subsonic.');
    await gate?.future;
    return RemoteTrackData(
      bytes: switch (server) {
        _airsonicA => _audioOfA,
        _airsonicB => _audioOfB,
        _ => _audioOfNavidrome,
      },
      fileExtension: 'mp3',
    );
  }
}

class _Stream implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async => ResolvedPlayable(
        Uri.parse('https://subsonic.example/stream/${track.id}'),
        PlaybackSource.streamingDirect,
      );
}

Track _song(String id, String title) =>
    Track(id: id, title: title, uri: 'subsonic:$id');

void main() {
  late FakeSubsonicClient client;
  late InMemoryOfflineFileStore files;
  late _SubsonicDownloader downloader;
  late ProviderContainer container;
  late SubsonicSettingsController subsonic;

  Future<void> start({
    SubsonicSession? signedIn = _signedInToA,
    List<CachedTrack> stored = const <CachedTrack>[],
  }) async {
    container = ProviderContainer(
      overrides: <Override>[
        subsonicClientProvider.overrideWithValue(client),
        subsonicSessionStoreProvider.overrideWithValue(
            InMemorySubsonicSessionStore(initialSession: signedIn)),
        musicLibraryRepositoryProvider
            .overrideWithValue(InMemoryMusicLibraryRepository()),
        preferredSourceStoreProvider
            .overrideWithValue(InMemoryPreferredSourceStore()),
        defaultProviderStoreProvider
            .overrideWithValue(InMemoryDefaultProviderStore()),
        remoteTrackDownloaderProvider.overrideWith((ref) => downloader =
            _SubsonicDownloader(
                () => ref.read(subsonicMusicSourceProvider)?.session.baseUrl)),
        connectivityServiceProvider.overrideWithValue(_Wifi()),
        offlineFileStoreProvider.overrideWithValue(files),
        downloadStoreProvider
            .overrideWithValue(InMemoryDownloadStore(initialDownloads: stored)),
        // The app's own bindings.
        downloadAccountScopeOverride,
        offlineCopyOriginsOverride,
      ],
    );
    addTearDown(container.dispose);
    subsonic = container.read(subsonicSettingsControllerProvider.notifier);
    await subsonic.ensureLoaded();
  }

  setUp(() {
    client = FakeSubsonicClient(serverInfo: _airsonic);
    files = InMemoryOfflineFileStore();
  });

  DownloadRepository downloads() => container.read(downloadRepositoryProvider);

  Future<void> settle() async {
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Settings -> Subsonic: sign in to [url], a server reporting [info].
  Future<void> signInTo(
    String url, {
    SubsonicServerInfo info = _airsonic,
    String username = 'alice',
  }) async {
    client.serverInfo = info;
    expect(
      await subsonic.signIn(url: url, username: username, password: 'pw'),
      isTrue,
    );
    await settle();
    expect(subsonic.session!.baseUrl, url);
  }

  Future<void> signOut() async {
    await subsonic.clear();
    await settle();
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

  group('a server that numbers its songs', () {
    setUp(() => start());

    test(
        "after signing in to another server, the previous server's offline "
        "copy is not served for the new server's song with the same id",
        () async {
      expect(await downloads().requestDownload(_song('101', 'Song on A')),
          DownloadRequestOutcome.started);
      expect(await downloads().statusFor('101'), DownloadStatus.downloaded);

      await signOut();
      await signInTo(_airsonicB);

      // Never downloaded on this server: its row must not read "Downloaded",
      // and it must stream rather than play server A's song 101.
      final Track songOnB = _song('101', 'Song on B');
      expect(await rowOf(songOnB), isNull,
          reason: "B's song reads as downloaded");
      expect(await offlineBytes(songOnB), isNull,
          reason: "server A's audio is served for B's song");
      expect((await play(songOnB)).source, PlaybackSource.streamingDirect);
    });

    test(
        'the same for a pre-cached copy, signing in to the other server '
        'straight away', () async {
      // Smart pre-cache warmed server A's song 202 ahead of play.
      await container
          .read(trackPrefetcherProvider)
          .prefetch(_song('202', 'Song on A'));
      expect(
          (await container.read(offlineCacheManagerProvider).cacheSnapshot())
              .entries
              .single
              .preloaded,
          isTrue);

      await signInTo(_airsonicB);

      expect((await play(_song('202', 'Song on B'))).source,
          PlaybackSource.streamingDirect,
          reason: "server A's pre-cached audio plays for B's song");
    });

    test(
        'a pre-cache still fetching from the previous server is not saved '
        "for the new server's song", () async {
      // Builds the repository, and with it the downloader.
      await downloads().statusFor('303');
      downloader.gate = Completer<void>();
      final Future<void> warming = container
          .read(trackPrefetcherProvider)
          .prefetch(_song('303', 'Song on A'));
      await settle();

      await signInTo(_airsonicB);
      downloader.gate!.complete();
      await warming;

      expect(await offlineBytes(_song('303', 'Song on B')), isNull,
          reason: "server A's audio is served for B's song");
      expect(
          (await container.read(offlineCacheManagerProvider).cacheSnapshot())
              .entries,
          isEmpty);
    });

    test("downloading the new server's song fetches its own audio", () async {
      await downloads().requestDownload(_song('101', 'Song on A'));
      await signInTo(_airsonicB);

      // Not "already downloaded": the request fetches B's bytes.
      expect(await downloads().requestDownload(_song('101', 'Song on B')),
          DownloadRequestOutcome.started);
      expect(await rowOf(_song('101', 'Song on B')), DownloadStatus.downloaded);
      expect(await offlineBytes(_song('101', 'Song on B')), _audioOfB);
    });

    test("each server's copy of the same id is kept apart", () async {
      await downloads().requestDownload(_song('101', 'Song on A'));
      await signInTo(_airsonicB);
      await downloads().requestDownload(_song('101', 'Song on B'));

      await signInTo(_airsonicA);
      expect(await offlineBytes(_song('101', 'Song on A')), _audioOfA,
          reason: "B's copy was written over server A's file");

      await signInTo(_airsonicB);
      expect(await offlineBytes(_song('101', 'Song on B')), _audioOfB);
    });

    test('the copy comes back when its own server is signed in again',
        () async {
      final Track songOnA = _song('101', 'Song on A');
      await downloads().requestDownload(songOnA);
      await signInTo(_airsonicB);
      expect(await rowOf(songOnA), isNull);

      await signInTo(_airsonicA);

      expect(await rowOf(songOnA), DownloadStatus.downloaded);
      expect((await play(songOnA)).source, PlaybackSource.offlineCache);
      expect(await offlineBytes(songOnA), _audioOfA);
    });

    test('another account on the same server keeps its copies in use',
        () async {
      // Song ids are the server's, the same for every account on it.
      final Track songOnA = _song('101', 'Song on A');
      await downloads().requestDownload(songOnA);

      await signOut();
      await signInTo(_airsonicA, username: 'bob');

      expect(await rowOf(songOnA), DownloadStatus.downloaded);
      expect(await offlineBytes(songOnA), _audioOfA);
    });

    test(
        'signed out, the copy is set aside, since nothing says which server '
        'the next song 101 is from, and it is back on signing in again',
        () async {
      final Track songOnA = _song('101', 'Song on A');
      await downloads().requestDownload(songOnA);

      await signOut();
      expect(await offlineBytes(songOnA), isNull);

      await signInTo(_airsonicA);
      expect(await offlineBytes(songOnA), _audioOfA);
    });
  });

  test(
      'a copy saved before copies were bound is taken as the signed-in '
      "server's, and set aside on another server", () async {
    // Downloaded on A by an earlier version: no server recorded.
    final OfflineFileDraft draft = await files.createDraft('subsonic_101');
    await draft.add(_audioOfA);
    final String fileName = await draft.publish(extension: 'mp3');
    await start(stored: <CachedTrack>[
      CachedTrack(
        trackId: '101',
        fileName: fileName,
        sourceType: 'subsonic',
        sizeBytes: _audioOfA.length,
      ),
    ]);
    expect(await rowOf(_song('101', 'Song on A')), DownloadStatus.downloaded);

    await signInTo(_airsonicB);
    expect(await offlineBytes(_song('101', 'Song on B')), isNull);

    await signInTo(_airsonicA);
    expect(await offlineBytes(_song('101', 'Song on A')), _audioOfA);
  });

  group('Navidrome', () {
    setUp(() async {
      client = FakeSubsonicClient(serverInfo: _navidrome);
      await start(signedIn: null);
      await signInTo(_navidromeLan, info: _navidrome);
    });

    test(
        "another Navidrome's song with the same id is not the copy's, and "
        'the copy is back at its own address', () async {
      // Navidrome's ids come from file paths: another installation can have
      // another file at the same path. All Linthra knows of a server is its
      // address, so another address may be another installation.
      final Track song = _song('2f1e0c', 'Song');
      await downloads().requestDownload(song);

      await signOut();
      await signInTo(_navidromeProxy, info: _navidrome);
      final Track other = _song('2f1e0c', 'Another song');
      expect(await rowOf(other), isNull);
      expect(await offlineBytes(other), isNull);
      expect((await play(other)).source, PlaybackSource.streamingDirect);

      await signInTo(_navidromeLan, info: _navidrome);
      expect(await rowOf(song), DownloadStatus.downloaded);
      expect((await play(song)).source, PlaybackSource.offlineCache);
      expect(await offlineBytes(song), _audioOfNavidrome);
    });

    test('signed out, a copy is set aside like any other, and comes back',
        () async {
      final Track song = _song('2f1e0c', 'Song');
      await downloads().requestDownload(song);

      await signOut();
      expect(await offlineBytes(song), isNull);

      await signInTo(_navidromeLan, info: _navidrome);
      expect(await offlineBytes(song), _audioOfNavidrome);
    });

    test("another server's copy stays set aside while Navidrome is connected",
        () async {
      await signInTo(_airsonicA);
      await downloads().requestDownload(_song('101', 'Song on A'));

      await signInTo(_navidromeLan, info: _navidrome);

      // A real Navidrome id is a hash of a path, so this one is contrived,
      // but whether a copy plays can't hang on what its id looks like.
      final Track songOnNavidrome = _song('101', 'Song on Navidrome');
      expect(await rowOf(songOnNavidrome), isNull,
          reason: "server A's copy reads as downloaded on Navidrome");
      expect(await offlineBytes(songOnNavidrome), isNull,
          reason: "server A's audio is served on Navidrome");
    });

    test("a Navidrome copy isn't taken for the next server's song", () async {
      final Track song = _song('2f1e0c', 'Song');
      await downloads().requestDownload(song);

      await signInTo(_airsonicA);
      final Track songOnA = _song('2f1e0c', 'Song on A');
      expect(await rowOf(songOnA), isNull,
          reason: "server A's song reads as downloaded");
      expect(await offlineBytes(songOnA), isNull,
          reason: "Navidrome's audio is served for server A's song");

      // Still that Navidrome's: back on it, it plays.
      await signInTo(_navidromeLan, info: _navidrome);
      expect(await rowOf(song), DownloadStatus.downloaded);
      expect(await offlineBytes(song), _audioOfNavidrome);
    });

    test("a visit to Navidrome doesn't unbind another server's copies",
        () async {
      await signInTo(_airsonicA);
      final Track songOnA = _song('101', 'Song on A');
      await downloads().requestDownload(songOnA);

      await signInTo(_navidromeLan, info: _navidrome);
      await signInTo(_airsonicB);
      expect(await offlineBytes(_song('101', 'Song on B')), isNull);

      await signInTo(_airsonicA);
      expect(await offlineBytes(songOnA), _audioOfA);
    });
  });
}
