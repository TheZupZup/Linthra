import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/services/smart_precache_service.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

class _Connectivity implements ConnectivityService {
  _Connectivity(this.status);

  NetworkStatus status;

  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// Holds every fetch open until the test releases it, recording the order.
class _HeldDownloader implements RemoteTrackDownloader {
  final List<String> fetched = <String>[];
  final List<Completer<void>> gates = <Completer<void>>[];

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetched.add(track.id);
    final Completer<void> gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    onProgress?.call(4, 4);
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }

  /// Lets every fetch started so far finish.
  void releaseAll() {
    for (final Completer<void> gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

Track _t(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

Future<void> _settle() async {
  for (int i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late InMemoryDownloadStore store;
  late InMemoryOfflineFileStore files;
  late _HeldDownloader downloader;
  late StreamController<PlaybackState> states;

  setUp(() {
    store = InMemoryDownloadStore();
    files = InMemoryOfflineFileStore();
    downloader = _HeldDownloader();
    states = StreamController<PlaybackState>.broadcast();
  });

  tearDown(() => states.close());

  /// The app shares one preferences object between Settings and both the
  /// cache repository and the pre-cache service; so does this.
  ({CacheDownloadRepository repo, SmartPrecacheService service}) build(
    InMemoryDownloadPreferences preferences,
    NetworkStatus network,
  ) {
    final CacheDownloadRepository repo = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: downloader,
      connectivity: _Connectivity(network),
      preferences: preferences,
    );
    final SmartPrecacheService service = SmartPrecacheService(
      playbackStates: states.stream,
      prefetcher: repo,
      preferences: preferences,
    );
    addTearDown(service.dispose);
    return (repo: repo, service: service);
  }

  /// Plays `now` with a long up-next list and waits until the first warm is
  /// in flight.
  Future<void> startLongPass() async {
    states.add(PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _t('now'),
      upNext: <Track>[for (int i = 1; i <= 10; i++) _t('n$i')],
    ));
    await _settle();
    expect(downloader.fetched, <String>['n1']);
  }

  /// Lets the pass run to its end, one fetch at a time.
  Future<void> drain() async {
    for (int i = 0; i < 20; i++) {
      downloader.releaseAll();
      await _settle();
    }
  }

  Future<Set<String>> cachedIds() async => <String>{
        for (final CachedTrack c in await store.loadDownloads()) c.trackId,
      };

  // A pass warms the next few songs one at a time (up to 200 when the count
  // is set that high), so a setting can change while it is still running.
  group('a pass that is already running', () {
    test('stops when smart pre-cache is turned off', () async {
      final InMemoryDownloadPreferences preferences =
          InMemoryDownloadPreferences(precacheCount: 10);
      build(preferences, NetworkStatus.wifi);
      await startLongPass();

      // Settings: "Pre-cache upcoming tracks" off. The screen promises this
      // stops Linthra fetching song data on its own.
      await preferences.setPreloadEnabled(false);
      await drain();

      // At most the fetch already in flight may finish; nothing new starts.
      expect(downloader.fetched, <String>['n1']);
      expect((await cachedIds()).difference(<String>{'n1'}), isEmpty);
    });

    test('stops when "Save data" is picked on mobile data', () async {
      final InMemoryDownloadPreferences preferences =
          InMemoryDownloadPreferences(
        precacheCount: 10,
        mobileDataProfile: MobileDataProfile.unlimited,
      );
      build(preferences, NetworkStatus.mobile);
      await startLongPass();

      // Settings: "Save data" pauses automatic smart pre-cache on metered data.
      await preferences.setMobileDataProfile(MobileDataProfile.saveData);
      await drain();

      expect(downloader.fetched, <String>['n1']);
    });
  });
}
