import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/download_scheduler.dart';
import 'package:linthra/core/services/offline_cache_manager.dart';
import 'package:linthra/core/services/offline_first_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/services/smart_precache_service.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';

/// A connectivity stand-in whose reported status the test can flip at will.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity(this.status);

  NetworkStatus status;

  @override
  Stream<NetworkStatus> get statusStream => Stream<NetworkStatus>.value(status);

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// A remote downloader fake: treats `jellyfin:` tracks as remote and returns
/// canned bytes, or throws when [error] is set, so the repository's remote path
/// can be driven without a server or HTTP.
///
/// When [gate] is set, every [fetch] awaits it before completing, so a test can
/// hold downloads in flight and observe how many run at once ([maxActive]).
/// [error] is mutable so a test can fail an attempt, then clear it and retry.
class _FakeRemoteDownloader implements RemoteTrackDownloader {
  _FakeRemoteDownloader({
    this.error,
    this.gate,
    this.schemes = const <String>['jellyfin:'],
  });

  /// The canned bytes every successful fetch returns.
  static const List<int> bytes = <int>[1, 2, 3, 4];

  /// When set, [fetch] throws this instead of returning bytes.
  Object? error;

  /// When set, [fetch] awaits this before completing.
  final Future<void>? gate;

  /// The remote URI schemes this fake claims. Defaults to Jellyfin so existing
  /// tests are unchanged; the Plex group overrides it (and the isolation test
  /// claims both providers at once).
  final List<String> schemes;

  int fetchCount = 0;
  int activeNow = 0;
  int maxActive = 0;
  final List<Track> fetched = <Track>[];

  @override
  bool isRemote(Track track) => schemes.any(track.uri.startsWith);

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetchCount++;
    activeNow++;
    if (activeNow > maxActive) maxActive = activeNow;
    fetched.add(track);
    try {
      onProgress?.call(2, bytes.length);
      final Future<void>? pending = gate;
      if (pending != null) await pending;
      final Object? err = error;
      if (err != null) throw err;
      onProgress?.call(bytes.length, bytes.length);
      return const RemoteTrackData(bytes: bytes, fileExtension: 'mp3');
    } finally {
      activeNow--;
    }
  }
}

/// Wraps [InMemoryDownloadPreferences] and can hold [maxCacheBytes] open.
///
/// That call is the first await inside a cache commit, so gating it parks a
/// commit *before* it evicts anything, which is the window a request queued
/// behind it has to survive.
class _GatedPreferences implements DownloadPreferences {
  _GatedPreferences(this._inner);

  final InMemoryDownloadPreferences _inner;

  /// When set, [maxCacheBytes] awaits it before answering.
  Completer<void>? gate;

  /// Completes once [maxCacheBytes] has actually been reached and parked, so a
  /// test never races the commit it means to hold.
  final Completer<void> reachedGate = Completer<void>();

  @override
  Future<int> maxCacheBytes() async {
    final Completer<void>? pending = gate;
    if (pending != null) {
      if (!reachedGate.isCompleted) reachedGate.complete();
      await pending.future;
    }
    return _inner.maxCacheBytes();
  }

  @override
  Future<void> setMaxCacheBytes(int bytes) => _inner.setMaxCacheBytes(bytes);

  @override
  Future<bool> allowMobileData() => _inner.allowMobileData();

  @override
  Future<void> setAllowMobileData(bool value) =>
      _inner.setAllowMobileData(value);

  @override
  Future<MobileDataProfile> mobileDataProfile() => _inner.mobileDataProfile();

  @override
  Future<void> setMobileDataProfile(MobileDataProfile profile) =>
      _inner.setMobileDataProfile(profile);

  @override
  Future<bool> preloadEnabled() => _inner.preloadEnabled();

  @override
  Future<void> setPreloadEnabled(bool value) => _inner.setPreloadEnabled(value);

  @override
  Future<int> precacheCount() => _inner.precacheCount();

  @override
  Future<void> setPrecacheCount(int value) => _inner.setPrecacheCount(value);
}

/// Wraps an in-memory file store and records every delete, so a test can prove
/// the cache only ever deletes app-managed files (never a local source file).
class _SpyOfflineFileStore implements OfflineFileStore {
  _SpyOfflineFileStore(this._inner);

  final InMemoryOfflineFileStore _inner;
  final List<String> deleted = <String>[];

  List<int>? bytesFor(String fileName) => _inner.bytesFor(fileName);

  @override
  Future<String> write(String trackId, List<int> bytes, {String? extension}) =>
      _inner.write(trackId, bytes, extension: extension);

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) => _inner.sizeFor(fileName);

  @override
  Future<void> delete(String fileName) {
    deleted.add(fileName);
    return _inner.delete(fileName);
  }
}

/// A connectivity stand-in whose [currentStatus] can be held open, so a
/// connection change can land while a request is still asking the policy.
class _GatedConnectivity implements ConnectivityService {
  _GatedConnectivity(this.status);

  NetworkStatus status;

  /// When set, [currentStatus] waits on it, then answers with the status it
  /// read when it was asked.
  Completer<void>? gate;
  final Completer<void> reached = Completer<void>();

  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async {
    final NetworkStatus asked = status;
    final Completer<void>? pending = gate;
    if (pending != null && !pending.isCompleted) {
      if (!reached.isCompleted) reached.complete();
      await pending.future;
      return asked;
    }
    return status;
  }
}

/// One fetch held by [_PerCallDownloader] until the test settles it.
class _HeldFetch {
  final Completer<void> _gate = Completer<void>();
  Object? _error;

  void complete() => _gate.complete();

  void fail(Object error) {
    _error = error;
    _gate.complete();
  }
}

/// A remote downloader whose every fetch waits on its own [_HeldFetch], in
/// call order, so a test decides which of two overlapping fetches of the same
/// track lands first.
class _PerCallDownloader implements RemoteTrackDownloader {
  final List<_HeldFetch> calls = <_HeldFetch>[];

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final _HeldFetch held = _HeldFetch();
    calls.add(held);
    await held._gate.future;
    final Object? error = held._error;
    if (error != null) throw error;
    onProgress?.call(4, 4);
    return const RemoteTrackData(
        bytes: <int>[1, 2, 3, 4], fileExtension: 'mp3');
  }
}

/// Holds the first [write] until [release] completes, after the bytes are on
/// disk but before it returns: the moment a commit has written the file and
/// not yet recorded it.
class _GatedWriteFileStore implements OfflineFileStore {
  _GatedWriteFileStore(this._inner);

  final InMemoryOfflineFileStore _inner;
  final Completer<void> reachedWrite = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<String> write(String trackId, List<int> bytes,
      {String? extension}) async {
    final String name =
        await _inner.write(trackId, bytes, extension: extension);
    if (!reachedWrite.isCompleted) {
      reachedWrite.complete();
      await release.future;
    }
    return name;
  }

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) => _inner.sizeFor(fileName);

  @override
  Future<void> delete(String fileName) => _inner.delete(fileName);
}

/// A streaming fallback that records the track it was asked to resolve and
/// returns a canned "streaming direct" result — stands in for the real
/// Jellyfin/Subsonic/Plex resolvers so [OfflineFirstPlayableUriResolver] can be
/// exercised without a server (issue #356: streaming must still work when
/// nothing is cached).
class _RecordingStreamResolver implements PlayableUriResolver {
  Track? resolved;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    resolved = track;
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.id}'),
      PlaybackSource.streamingDirect,
    );
  }
}

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');
Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');
Track _plex(String id) => Track(id: id, title: id, uri: 'plex:$id');
Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

void main() {
  group('CacheDownloadRepository', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _FakeRemoteDownloader downloader;

    CacheDownloadRepository build() {
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
      );
    }

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      preferences = InMemoryDownloadPreferences();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      downloader = _FakeRemoteDownloader();
    });

    test('a Jellyfin track starts not downloaded', () async {
      final repository = build();
      expect(
        await repository.statusFor('j1'),
        DownloadStatus.notDownloaded,
      );
      expect(await repository.downloadedTrackKeys(), isEmpty);
    });

    test('downloading a Jellyfin track stores a cached file reference',
        () async {
      final repository = build();

      await repository.requestDownload(_jellyfin('j1'));

      expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      expect(downloader.fetchCount, 1);

      final List<CachedTrack> saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.trackId, 'j1');
      expect(saved.single.fileName, isNotNull);
      // The fetched bytes were written to the cache under that file name.
      expect(files.bytesFor(saved.single.fileName!), <int>[1, 2, 3, 4]);
    });

    test('removing a downloaded Jellyfin track deletes the cached file',
        () async {
      final repository = build();
      await repository.requestDownload(_jellyfin('j1'));
      final String fileName = (await store.loadDownloads()).single.fileName!;

      await repository.removeDownload(_jellyfin('j1'));

      expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      expect(await repository.downloadedTrackKeys(), isEmpty);
      expect(await store.loadDownloads(), isEmpty);
      expect(files.bytesFor(fileName), isNull);
    });

    test('a failed remote fetch surfaces as failed and stores nothing',
        () async {
      downloader = _FakeRemoteDownloader(error: Exception('boom'));
      final repository = build();

      await repository.requestDownload(_jellyfin('j1'));

      expect(await repository.statusFor('j1'), DownloadStatus.failed);
      expect(await store.loadDownloads(), isEmpty);
      expect(await repository.downloadedTrackKeys(), isEmpty);
    });

    test('a failed Jellyfin track can be retried', () async {
      downloader = _FakeRemoteDownloader(error: Exception('boom'));
      final repository = build();
      await repository.requestDownload(_jellyfin('j1'));
      expect(await repository.statusFor('j1'), DownloadStatus.failed);

      // A retry with a downloader that now succeeds reaches downloaded.
      downloader = _FakeRemoteDownloader();
      final retryRepository = CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
      );
      await retryRepository.requestDownload(_jellyfin('j1'));

      expect(await retryRepository.statusFor('j1'), DownloadStatus.downloaded);
    });

    group('local tracks are treated as already local', () {
      test('a local track is recorded without a remote fetch or cached file',
          () async {
        final repository = build();

        await repository.requestDownload(_local('a'));

        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
        // No remote fetch happened, and no managed cache file was written.
        expect(downloader.fetchCount, 0);
        final List<CachedTrack> saved = await store.loadDownloads();
        expect(saved.single.trackId, 'a');
        expect(saved.single.fileName, isNull);
      });

      test('removing a local track clears it without touching files', () async {
        final repository = build();
        await repository.requestDownload(_local('a'));

        await repository.removeDownload(_local('a'));

        expect(await repository.statusFor('a'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
      });
    });

    test('no token is stored in the track uri or the cache metadata', () async {
      const String token = 'super-secret-token';
      // Even if a downloader's source minted a tokenized URL, the repository
      // only ever sees bytes — the persisted file name is derived from the id.
      final track = _jellyfin('item-42');
      final repository = build();

      await repository.requestDownload(track);

      final CachedTrack saved = (await store.loadDownloads()).single;
      expect(saved.trackId, 'item-42');
      expect(saved.fileName, isNot(contains(token)));
      expect(saved.fileName, isNot(contains('api_key')));
      // The track itself still carries only the opaque jellyfin: uri.
      expect(track.uri, 'jellyfin:item-42');
    });

    test('downloaded references are reloaded by a fresh repository', () async {
      await build().requestDownload(_jellyfin('j1'));

      final reopened = build();
      expect(await reopened.statusFor('j1'), DownloadStatus.downloaded);
      expect(await reopened.downloadedTrackKeys(),
          <String>[CachedTrack.cacheKeyForTrack(_jellyfin('j1'))]);
    });

    test('the downloaded projection is provider-aware for same-id copies',
        () async {
      // Two providers expose the same bare id 101; only the Subsonic copy is
      // downloaded. The public projection (downloaded keys + status snapshot)
      // must mark that copy alone — never the Jellyfin copy sharing the id.
      final repository = build();
      await repository.requestDownload(_subsonic('101'));

      final String subKey = CachedTrack.cacheKeyForTrack(_subsonic('101'));
      final String jellyKey = CachedTrack.cacheKeyForTrack(_jellyfin('101'));
      expect(await repository.downloadedTrackKeys(), <String>[subKey]);

      final Map<String, DownloadStatus> snapshot =
          await repository.statusStream.first;
      expect(snapshot[subKey], DownloadStatus.downloaded);
      expect(snapshot.containsKey(jellyKey), isFalse);
    });

    test('migrates a legacy (sourceType-less) record to a provider-aware key',
        () async {
      // Seed a pre-v0.1.6 download: a managed file plus a CachedTrack with no
      // sourceType, which keys as `\0101`.
      files = InMemoryOfflineFileStore();
      final String fileName =
          await files.write('101', <int>[1, 2, 3, 4], extension: 'mp3');
      store = InMemoryDownloadStore(initialDownloads: <CachedTrack>[
        CachedTrack(trackId: '101', fileName: fileName, sizeBytes: 4),
      ]);
      // The catalog resolves bare id 101 to one provider (1:1 pre-upgrade).
      final repository = CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
        catalogForMigration: () async => <Track>[_jellyfin('101')],
      );

      // The download now resolves under the provider-aware key…
      expect(await repository.downloadedTrackKeys(),
          <String>[CachedTrack.cacheKeyForTrack(_jellyfin('101'))]);
      // …and the record was re-saved with the inferred sourceType (so it stays
      // provider-aware next launch), with its cache file untouched.
      final List<CachedTrack> saved = await store.loadDownloads();
      expect(saved.single.sourceType, 'jellyfin');
      expect(saved.single.fileName, fileName);
    });

    test('leaves a legacy record unmigrated when its bare id is ambiguous',
        () async {
      files = InMemoryOfflineFileStore();
      final String fileName =
          await files.write('101', <int>[1, 2, 3, 4], extension: 'mp3');
      store = InMemoryDownloadStore(initialDownloads: <CachedTrack>[
        CachedTrack(trackId: '101', fileName: fileName, sizeBytes: 4),
      ]);
      // Two providers now expose id 101 — the legacy download can't be safely
      // attributed, so it must be left as-is rather than mis-keyed.
      final repository = CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
        catalogForMigration: () async =>
            <Track>[_jellyfin('101'), _subsonic('101')],
      );

      expect(await repository.downloadedTrackKeys(),
          <String>[CachedTrack.cacheKeyFor(null, '101')]);
      expect((await store.loadDownloads()).single.sourceType, isNull);
    });

    test('a migrated legacy cache belongs only to the matched provider copy',
        () async {
      // Pre-v0.1.6 the catalog was 1:1, so a legacy download for id 101 was one
      // provider's (Plex here). After it migrates, a later same-bare-id copy from
      // another provider (subsonic:101) must NOT inherit the download.
      files = InMemoryOfflineFileStore();
      final String fileName =
          await files.write('101', <int>[1, 2, 3, 4], extension: 'mp3');
      store = InMemoryDownloadStore(initialDownloads: <CachedTrack>[
        CachedTrack(trackId: '101', fileName: fileName, sizeBytes: 4),
      ]);
      final repository = CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
        catalogForMigration: () async => <Track>[_plex('101')],
      );

      // Migrated to the Plex copy only…
      expect(await repository.downloadedTrackKeys(),
          <String>[CachedTrack.cacheKeyForTrack(_plex('101'))]);
      // …so a same-id Subsonic copy is not seen as downloaded.
      final Map<String, DownloadStatus> snapshot =
          await repository.statusStream.first;
      expect(
          snapshot.containsKey(CachedTrack.cacheKeyForTrack(_subsonic('101'))),
          isFalse);
      expect(await repository.statusFor('101'), DownloadStatus.downloaded);
    });

    test('statusStream seeds the current snapshot then emits changes',
        () async {
      await build().requestDownload(_jellyfin('j1'));
      final repository = build();

      final emissions = <Map<String, DownloadStatus>>[];
      final sub = repository.statusStream.listen(emissions.add);
      await _settle();

      expect(emissions.first, <String, DownloadStatus>{
        CachedTrack.cacheKeyForTrack(_jellyfin('j1')):
            DownloadStatus.downloaded,
      });

      await repository.requestDownload(_jellyfin('j2'));
      await _settle();

      expect(emissions.last[CachedTrack.cacheKeyForTrack(_jellyfin('j2'))],
          DownloadStatus.downloaded);
      await sub.cancel();
    });

    test('a downloaded track is not re-downloaded', () async {
      final repository = build();
      await repository.requestDownload(_jellyfin('j1'));
      expect(downloader.fetchCount, 1);

      await repository.requestDownload(_jellyfin('j1'));

      // No second fetch was attempted.
      expect(downloader.fetchCount, 1);
    });

    group('mobile-data policy (remote downloads)', () {
      test('Wi-Fi only by default: queues on mobile and reports why', () async {
        // Default preference: mobile data is not allowed.
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.waitingForWifi);
        expect(await repository.statusFor('j1'), DownloadStatus.queued);
        expect(downloader.fetchCount, 0);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('downloads when on Wi-Fi even with mobile data not allowed',
          () async {
        connectivity.status = NetworkStatus.wifi;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.started);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('downloads over mobile when the user allows mobile data', () async {
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.started);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('queues with a connection-waiting reason when offline', () async {
        // Even with mobile data allowed, offline means there is no link to use.
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.offline;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_jellyfin('j1'));

        expect(outcome, DownloadRequestOutcome.waitingForConnection);
        expect(await repository.statusFor('j1'), DownloadStatus.queued);
        expect(downloader.fetchCount, 0);
      });

      test('treats an unknown connection conservatively, like mobile data',
          () async {
        connectivity.status = NetworkStatus.unknown;
        final repository = build();

        // Mobile data not allowed: an unknown link is held for Wi-Fi…
        expect(
          await repository.requestDownload(_jellyfin('j1')),
          DownloadRequestOutcome.waitingForWifi,
        );
        expect(await repository.statusFor('j1'), DownloadStatus.queued);

        // …and allowed once the user opts into mobile data.
        await preferences.setAllowMobileData(true);
        expect(
          await repository.requestDownload(_jellyfin('j1')),
          DownloadRequestOutcome.started,
        );
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('a local track is never queued, even on mobile data', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        final DownloadRequestOutcome outcome =
            await repository.requestDownload(_local('a'));

        // Already local: the network gate doesn't apply (no bytes to fetch).
        expect(outcome, DownloadRequestOutcome.started);
        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
      });

      test('a queued track downloads on an explicit retry once on Wi-Fi',
          () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = build();
        await repository.requestDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.queued);

        connectivity.status = NetworkStatus.wifi;
        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('blocked-download messages are friendly and secret-free', () async {
        // No URL, token, scheme, or path leaks into what the user would see.
        const String wifi =
            'Downloads are limited to Wi-Fi. Turn on "Allow mobile data" in '
            'Settings to download over mobile data.';
        const String offline =
            "You're offline. This download will start automatically when "
            "you're back online.";
        expect(DownloadRequestOutcome.waitingForWifi.blockedMessage, wifi);
        expect(
          DownloadRequestOutcome.waitingForConnection.blockedMessage,
          offline,
        );
        expect(DownloadRequestOutcome.started.blockedMessage, isNull);
        for (final String message in <String>[wifi, offline]) {
          expect(message, isNot(contains('jellyfin:')));
          expect(message, isNot(contains('http')));
          expect(message, isNot(contains('token')));
          expect(message, isNot(contains('/')));
        }
      });
    });

    group('cache metadata', () {
      test('a download records size, timestamps and source type', () async {
        final repository = build();

        await repository.requestDownload(_jellyfin('j1'));

        final CachedTrack saved = (await store.loadDownloads()).single;
        // Each canned fetch returns 4 bytes.
        expect(saved.sizeBytes, 4);
        expect(saved.cachedAt, isNotNull);
        expect(saved.lastAccessedAt, isNotNull);
        // The non-secret URI scheme, never the full URL/token.
        expect(saved.sourceType, 'jellyfin');
        expect(saved.pinned, isFalse);
      });

      test('cacheSnapshot totals only app-managed bytes', () async {
        final repository = build();
        await repository.requestDownload(_jellyfin('j1')); // 4 managed bytes
        await repository.requestDownload(_local('a')); // on-device, 0 bytes

        final CacheSnapshot snapshot = await repository.cacheSnapshot();
        expect(snapshot.usedBytes, 4);
        expect(snapshot.entries, hasLength(2));
        expect(snapshot.managedCount, 1);
      });

      test('a managed entry missing its size is backfilled from disk on load',
          () async {
        // Simulate a record written by an earlier version: file present, but
        // no sizeBytes recorded.
        final String fileName = await files
            .write('j1', const <int>[1, 2, 3, 4, 5], extension: 'mp3');
        await store.saveDownloads(<CachedTrack>[
          CachedTrack(trackId: 'j1', fileName: fileName),
        ]);

        final repository = build();
        final CacheSnapshot snapshot = await repository.cacheSnapshot();

        expect(snapshot.usedBytes, 5);
        expect((await store.loadDownloads()).single.sizeBytes, 5);
      });

      test('stale metadata for a missing file is pruned on load', () async {
        final String present =
            await files.write('here', const <int>[1, 2, 3], extension: 'mp3');
        await store.saveDownloads(<CachedTrack>[
          CachedTrack(trackId: 'here', fileName: present, sizeBytes: 3),
          // Points at a file the store doesn't have (OS reclaimed it).
          const CachedTrack(
              trackId: 'gone', fileName: 'gone.mp3', sizeBytes: 9),
        ]);

        final repository = build();

        expect(await repository.statusFor('here'), DownloadStatus.downloaded);
        expect(
            await repository.statusFor('gone'), DownloadStatus.notDownloaded);
        // The prune is persisted, so the stale record doesn't linger.
        final List<CachedTrack> remaining = await store.loadDownloads();
        expect(remaining.map((c) => c.trackId), <String>['here']);
      });
    });

    group('cache limit and eviction', () {
      // A clock that advances one minute per call, so cachedAt/lastAccessedAt
      // are distinct and least-recently-used ordering is deterministic.
      DateTime Function() incrementingClock() {
        int tick = 0;
        return () => DateTime(2024, 1, 1).add(Duration(minutes: tick++));
      }

      CacheDownloadRepository buildLimited({
        required int maxBytes,
        Track? Function()? currentlyPlaying,
        DateTime Function()? now,
      }) {
        preferences = InMemoryDownloadPreferences(maxCacheBytes: maxBytes);
        return CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          currentlyPlayingTrack: currentlyPlaying,
          now: now,
        );
      }

      test('downloading under the limit succeeds without eviction', () async {
        // Room for two 4-byte downloads.
        final repository = buildLimited(maxBytes: 10);

        await repository.requestDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j2'));

        final List<String> ids = await repository.downloadedTrackKeys();
        ids.sort();
        expect(ids, <String>[
          CachedTrack.cacheKeyForTrack(_jellyfin('j1')),
          CachedTrack.cacheKeyForTrack(_jellyfin('j2')),
        ]);
        expect((await repository.cacheSnapshot()).usedBytes, 8);
      });

      test('downloading over the limit evicts the least-recently-used track',
          () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1')); // oldest
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
        // The evicted file's bytes are gone from disk.
        expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
      });

      test(
          'a song downloaded after pre-cache warmed it is not evicted before '
          'older downloads', () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1')); // oldest
        // Pre-cache warms j2 ahead of play, then the listener downloads it:
        // promoted in place, without a second fetch.
        await repository.prefetch(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j2'));
        expect(downloader.fetchCount, 2);
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        // j2 was downloaded after j1, so j1 is the least recently used, as
        // when j2 is fetched directly (the test above).
        expect(await repository.statusFor('j2'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test(
          'the cache limit is still enforced when downloading over mobile data',
          () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.mobile;

        await repository.requestDownload(_jellyfin('j1')); // oldest
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        // Allowing mobile data never lets the cache exceed its limit.
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(
          (await repository.cacheSnapshot()).usedBytes,
          lessThanOrEqualTo(10),
        );
      });

      test('playing a track refreshes it so a stale one is evicted instead',
          () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j2'));
        // j1 was just played, so j2 is now the least-recently-used.
        await repository.notePlayed(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j3'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test('pinned tracks are never evicted automatically', () async {
        final repository = buildLimited(maxBytes: 10, now: incrementingClock());

        await repository.requestDownload(_jellyfin('j1')); // oldest
        await repository.setPinned(_jellyfin('j1'), true);
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        // j1 is pinned, so the unpinned j2 goes instead.
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test('the currently playing track is never evicted', () async {
        final repository = buildLimited(
          maxBytes: 10,
          currentlyPlaying: () => _jellyfin('j1'),
          now: incrementingClock(),
        );

        await repository.requestDownload(_jellyfin('j1')); // oldest + playing
        await repository.requestDownload(_jellyfin('j2'));
        await repository.requestDownload(_jellyfin('j3')); // forces eviction

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j3'), DownloadStatus.downloaded);
      });

      test('refuses with a friendly, secret-free error when nothing is safe',
          () async {
        // Room for one 4-byte track only.
        final repository = buildLimited(maxBytes: 4);
        await repository.requestDownload(_jellyfin('j1'));
        await repository.setPinned(_jellyfin('j1'), true);

        Object? caught;
        try {
          await repository.requestDownload(_jellyfin('j2'));
        } catch (error) {
          caught = error;
        }

        expect(caught, isA<CacheStorageException>());
        // The error never carries a URL, token, or path.
        final String message = (caught! as CacheStorageException).message;
        expect(message.toLowerCase(), isNot(contains('http')));
        expect(message.toLowerCase(), isNot(contains('token')));
        expect(message, isNot(contains('/')));

        // j2 was not cached and j1 (pinned) was left untouched.
        expect(await repository.statusFor('j2'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect((await store.loadDownloads()).map((c) => c.trackId),
            <String>['j1']);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
      });
    });

    group('parallel downloads', () {
      test('runs several downloads at once, bounded by the concurrency limit',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          scheduler: DownloadScheduler(maxConcurrent: 2),
        );

        final futures = <Future<void>>[
          repository.requestDownload(_jellyfin('j1')),
          repository.requestDownload(_jellyfin('j2')),
          repository.requestDownload(_jellyfin('j3')),
        ];

        // Only two may fetch at once; the third waits its turn as "queued".
        await _pumpUntil(() => downloader.fetchCount >= 2);
        expect(downloader.fetchCount, 2);
        expect(downloader.maxActive, 2);

        final statuses = <DownloadStatus>[
          await repository.statusFor('j1'),
          await repository.statusFor('j2'),
          await repository.statusFor('j3'),
        ];
        expect(
          statuses.where((s) => s == DownloadStatus.downloading).length,
          2,
        );
        expect(statuses.where((s) => s == DownloadStatus.queued).length, 1);

        // Releasing the gate lets all three finish — still never more than two
        // fetching at any instant.
        gate.complete();
        await Future.wait(futures);
        expect(downloader.fetchCount, 3);
        expect(downloader.maxActive, 2);
        final List<String> ids = await repository.downloadedTrackKeys();
        ids.sort();
        expect(ids, <String>[
          CachedTrack.cacheKeyForTrack(_jellyfin('j1')),
          CachedTrack.cacheKeyForTrack(_jellyfin('j2')),
          CachedTrack.cacheKeyForTrack(_jellyfin('j3')),
        ]);
      });

      test('a duplicate request for the same track is not started twice',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final f1 = repository.requestDownload(_jellyfin('j1'));
        final f2 = repository.requestDownload(_jellyfin('j1'));

        // The second request bails on the in-flight guard before fetching.
        await _pumpUntil(() => downloader.fetchCount >= 1);
        expect(downloader.fetchCount, 1);

        gate.complete();
        await Future.wait(<Future<void>>[f1, f2]);

        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('respects the cache limit even when downloads finish concurrently',
          () async {
        // Room for exactly two 4-byte downloads.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 8);
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          scheduler: DownloadScheduler(maxConcurrent: 3),
        );

        final futures = <Future<void>>[
          repository.requestDownload(_jellyfin('j1')),
          repository.requestDownload(_jellyfin('j2')),
          repository.requestDownload(_jellyfin('j3')),
        ];
        // All three fetch in parallel, then commit serially once released.
        await _pumpUntil(() => downloader.fetchCount >= 3);
        expect(downloader.maxActive, 3);
        gate.complete();
        await Future.wait(futures);

        // The serialized commit kept usage at the limit (never 12), evicting
        // the least-recently-used one to make room for the third.
        final CacheSnapshot snapshot = await repository.cacheSnapshot();
        expect(snapshot.usedBytes, 8);
        expect(snapshot.managedCount, 2);
      });

      test('reports byte progress while downloading, then clears it on finish',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final String j1Key = CachedTrack.cacheKeyForTrack(_jellyfin('j1'));
        final emissions = <Map<String, DownloadProgress>>[];
        final sub = repository.progressStream.listen(emissions.add);

        final future = repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => emissions.any((m) => m[j1Key] != null));

        final DownloadProgress? mid = emissions.last[j1Key];
        expect(mid, isNotNull);
        expect(mid!.receivedBytes, 2);
        expect(mid.totalBytes, 4);
        expect(mid.fraction, 0.5);

        gate.complete();
        await future;
        await _settle();

        // Progress is cleared once the download finishes.
        expect(emissions.last[j1Key], isNull);
        await sub.cancel();
      });

      test('a failed download can be retried on the same repository', () async {
        downloader = _FakeRemoteDownloader(error: Exception('boom'));
        final repository = build();
        await repository.requestDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.failed);
        expect(downloader.fetchCount, 1);

        // Clear the fault and retry through the same repository instance: the
        // in-flight reservation was released, so the retry proceeds.
        downloader.error = null;
        await repository.requestDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(downloader.fetchCount, 2);
      });
    });

    group('preload (prefetch)', () {
      test('caches a remote track without giving it a download status',
          () async {
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        // Invisible as a download, but cached and counted toward usage.
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.downloadedTrackKeys(), isEmpty);
        final CachedTrack saved = (await store.loadDownloads()).single;
        expect(saved.trackId, 'j1');
        expect(saved.preloaded, isTrue);
        expect(saved.fileName, isNotNull);
        expect((await repository.cacheSnapshot()).usedBytes, 4);
      });

      test(
          'a preloaded copy evicted while its promotion waits is downloaded '
          'for real, not restored as a stale record', () async {
        // Room for exactly one 4-byte track, so caching the second costs the
        // first its place.
        final _GatedPreferences gated =
            _GatedPreferences(InMemoryDownloadPreferences(maxCacheBytes: 5));
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: gated,
        );

        // j1 is pre-cached ahead of play: a managed, preloaded copy.
        await repository.prefetch(_jellyfin('j1'));
        expect((await store.loadDownloads()).single.preloaded, isTrue);
        expect(downloader.fetchCount, 1);

        // Park j2's commit before it evicts anything, with j1 still in place.
        gated.gate = Completer<void>();
        final Future<DownloadRequestOutcome> second =
            repository.requestDownload(_jellyfin('j2'));
        await gated.reachedGate.future;

        // Now ask for j1. It sees the preloaded copy, so it takes the promotion
        // path and queues behind j2's commit, which is about to delete it.
        final Future<DownloadRequestOutcome> first =
            repository.requestDownload(_jellyfin('j1'));
        await _settle();

        gated.gate!.complete();
        await second;
        await first;

        // j1 came back by being fetched again, not by resurrecting a record
        // whose file j2's commit had already deleted.
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        final CachedTrack restored = (await store.loadDownloads())
            .firstWhere((CachedTrack c) => c.trackId == 'j1');
        expect(restored.preloaded, isFalse);
        // The record points at bytes that are really on disk.
        expect(files.bytesFor(restored.fileName!), isNotNull);
        expect(downloader.fetched.map((Track t) => t.id), contains('j1'));
        expect(downloader.fetchCount, greaterThan(2));
      });

      test('skips a local track (already on disk)', () async {
        final repository = build();

        await repository.prefetch(_local('a'));

        expect(downloader.fetchCount, 0);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('skips a track that is already downloaded', () async {
        final repository = build();
        await repository.requestDownload(_jellyfin('j1'));
        expect(downloader.fetchCount, 1);

        await repository.prefetch(_jellyfin('j1'));

        expect(downloader.fetchCount, 1);
      });

      test('is best-effort: a failed fetch caches nothing and never throws',
          () async {
        downloader = _FakeRemoteDownloader(error: Exception('boom'));
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('skips (without queueing) on mobile when mobile data not allowed',
          () async {
        // Default: mobile data is not allowed, so pre-cache stays Wi-Fi-only.
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        expect(downloader.fetchCount, 0);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('runs on mobile when the user allows mobile data', () async {
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.mobile;
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        // Pre-cached over mobile, but it stays invisible as a download.
        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect((await store.loadDownloads()).single.preloaded, isTrue);
      });

      test('skips when offline, even with mobile data allowed', () async {
        await preferences.setAllowMobileData(true);
        connectivity.status = NetworkStatus.offline;
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));

        expect(downloader.fetchCount, 0);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('an explicit download promotes a preloaded copy without re-fetching',
          () async {
        final repository = build();
        await repository.prefetch(_jellyfin('j1'));
        expect(downloader.fetchCount, 1);

        await repository.requestDownload(_jellyfin('j1'));

        // Promoted in place: now a real download, still only one fetch total.
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(downloader.fetchCount, 1);
        expect((await store.loadDownloads()).single.preloaded, isFalse);
      });

      test('a preloaded track is evicted before a user download', () async {
        // Room for two 4-byte entries; a third forces one out.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 10);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('keep')); // user download
        await repository.prefetch(_jellyfin('warm')); // preload
        await repository.requestDownload(_jellyfin('new')); // forces eviction

        // The preload is sacrificed; the user download survives.
        expect(await repository.statusFor('keep'), DownloadStatus.downloaded);
        expect(await repository.statusFor('new'), DownloadStatus.downloaded);
        final List<String> ids = (await store.loadDownloads())
            .map((c) => c.trackId)
            .toList()
          ..sort();
        expect(ids, <String>['keep', 'new']);
      });

      test('a repeated pre-cache for the same track does not fetch twice',
          () async {
        final repository = build();

        await repository.prefetch(_jellyfin('j1'));
        await repository.prefetch(_jellyfin('j1'));

        // The second pre-cache bails on the already-cached guard before fetch.
        expect(downloader.fetchCount, 1);
        expect((await store.loadDownloads()).single.trackId, 'j1');
      });

      test(
          'respects the cache limit: a pre-cache that cannot fit is skipped, '
          'never throws, and evicts nothing protected', () async {
        // Room for exactly one 4-byte track, already taken by a pinned
        // ("Keep offline") download — nothing safe to evict.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 4);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('keep'));
        await repository.setPinned(_jellyfin('keep'), true);
        final int fetchesBefore = downloader.fetchCount;

        // Best-effort: never throws, caches nothing, and skips the fetch
        // entirely rather than spend data on bytes it would discard.
        await repository.prefetch(_jellyfin('warm'));

        expect(downloader.fetchCount, fetchesBefore);
        expect(await repository.statusFor('keep'), DownloadStatus.downloaded);
        expect(
          (await store.loadDownloads()).map((c) => c.trackId),
          <String>['keep'],
        );
        expect((await repository.cacheSnapshot()).usedBytes, 4);
      });

      test('evicts an older pre-cache to stay under the limit', () async {
        // Room for one 4-byte entry; a second pre-cache forces the first out.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 4);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );

        await repository.prefetch(_jellyfin('old'));
        await repository.prefetch(_jellyfin('new'));

        // The limit held: only the newest pre-cache remains, still invisible
        // as a download.
        expect((await repository.cacheSnapshot()).usedBytes, 4);
        final List<CachedTrack> saved = await store.loadDownloads();
        expect(saved.single.trackId, 'new');
        expect(saved.single.preloaded, isTrue);
        expect(await repository.downloadedTrackKeys(), isEmpty);
      });

      test('a pre-cache never evicts the currently playing track', () async {
        // Room for one 4-byte track, held by the currently playing track.
        preferences = InMemoryDownloadPreferences(maxCacheBytes: 4);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          currentlyPlayingTrack: () => _jellyfin('now'),
        );
        await repository.prefetch(_jellyfin('now'));
        expect((await store.loadDownloads()).single.trackId, 'now');

        // The only cached entry is the playing track (protected), so a new
        // pre-cache is skipped — the playing track is never evicted.
        await repository.prefetch(_jellyfin('next'));

        expect(
          (await store.loadDownloads()).map((c) => c.trackId),
          <String>['now'],
        );
        expect((await repository.cacheSnapshot()).usedBytes, 4);
      });
    });

    group('manual cache controls', () {
      test('clear all removes every managed file and its metadata', () async {
        final spy = _SpyOfflineFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: spy,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j2'));
        await repository.setPinned(_jellyfin('j1'), true);

        await repository.clearAll();

        // Pinned items included: clear-all is the nuclear option.
        expect(await repository.downloadedTrackKeys(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        expect(spy.bytesFor('jellyfin_j1.mp3'), isNull);
        expect(spy.bytesFor('jellyfin_j2.mp3'), isNull);
      });

      test('clear unpinned preserves pinned tracks', () async {
        final repository = build();
        await repository.requestDownload(_jellyfin('keep'));
        await repository.requestDownload(_jellyfin('drop'));
        await repository.setPinned(_jellyfin('keep'), true);

        await repository.clearUnpinned();

        expect(await repository.statusFor('keep'), DownloadStatus.downloaded);
        expect(
            await repository.statusFor('drop'), DownloadStatus.notDownloaded);
        expect(files.bytesFor('jellyfin_keep.mp3'), isNotNull);
        expect(files.bytesFor('jellyfin_drop.mp3'), isNull);
      });

      test('clearing never deletes a local source file', () async {
        final spy = _SpyOfflineFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: spy,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        await repository.requestDownload(_jellyfin('remote'));
        await repository.requestDownload(_local('song')); // local source file

        await repository.clearAll();

        // Only the app-managed remote file was ever handed to delete(); the
        // local track has no managed file, so its source is never touched.
        expect(spy.deleted, <String>['jellyfin_remote.mp3']);
        expect(spy.deleted.any((f) => f.contains('song')), isFalse);
      });

      test('cacheStream emits the current snapshot then changes', () async {
        final repository = build();
        final snapshots = <CacheSnapshot>[];
        final sub = repository.cacheStream.listen(snapshots.add);
        await _settle();

        expect(snapshots.first.usedBytes, 0);

        await repository.requestDownload(_jellyfin('j1'));
        await _settle();

        expect(snapshots.last.usedBytes, 4);
        await sub.cancel();
      });
    });

    group('cancel / clear races', () {
      test('cancelling a download mid-fetch never resurrects it', () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final spy = _SpyOfflineFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: spy,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );
        final progress = <Map<String, DownloadProgress>>[];
        final sub = repository.progressStream.listen(progress.add);

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        // Wait until the bytes are actually being fetched, then cancel.
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.removeDownload(_jellyfin('j1'));
        // The in-flight fetch now completes — it must commit nothing.
        gate.complete();
        await request;
        await _settle();

        // Settled as not downloaded, not left at "downloading".
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.downloadedTrackKeys(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        final CacheSnapshot snapshot = await repository.cacheSnapshot();
        expect(snapshot.usedBytes, 0);
        expect(snapshot.entries, isEmpty);
        // The cancelled fetch wrote no managed file at all.
        expect(spy.bytesFor('jellyfin_j1.mp3'), isNull);
        // Its progress ring is gone too.
        expect(progress.last, isEmpty);
        await sub.cancel();
      });

      test('cancelling a download queued for a slot never fetches it',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          scheduler: DownloadScheduler(maxConcurrent: 1),
        );
        final String bKey = CachedTrack.cacheKeyForTrack(_jellyfin('b'));
        final bStatuses = <DownloadStatus?>[];
        final statusSub =
            repository.statusStream.listen((m) => bStatuses.add(m[bKey]));
        final progress = <Map<String, DownloadProgress>>[];
        final progressSub = repository.progressStream.listen(progress.add);

        // One slot: a fetches while b and c wait their turn as "queued".
        final requests = <Future<void>>[
          repository.requestDownload(_jellyfin('a')),
          repository.requestDownload(_jellyfin('b')),
          repository.requestDownload(_jellyfin('c')),
        ];
        await _pumpUntil(() => downloader.fetchCount >= 1);
        expect(await repository.statusFor('b'), DownloadStatus.queued);

        await repository.removeDownload(_jellyfin('b'));
        gate.complete();
        await Future.wait(requests);
        await _settle();

        // b's turn came and went without a fetch; the slot passed on to c.
        expect(downloader.fetched.map((t) => t.id), <String>['a', 'c']);
        expect(await repository.statusFor('b'), DownloadStatus.notDownloaded);
        expect(bStatuses, isNot(contains(DownloadStatus.downloading)));
        expect(bStatuses.last, isNull);
        expect(files.bytesFor('jellyfin_b.mp3'), isNull);
        expect(progress.any((m) => m.containsKey(bKey)), isFalse);
        expect(progress.last, isEmpty);
        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
        expect(await repository.statusFor('c'), DownloadStatus.downloaded);

        // Nothing is left holding b: a later request downloads it normally.
        await repository.requestDownload(_jellyfin('b'));
        expect(await repository.statusFor('b'), DownloadStatus.downloaded);
        await statusSub.cancel();
        await progressSub.cancel();
      });

      test('re-requesting a download cancelled while queued still downloads it',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          scheduler: DownloadScheduler(maxConcurrent: 1),
        );

        final Future<void> a = repository.requestDownload(_jellyfin('a'));
        final Future<void> b = repository.requestDownload(_jellyfin('b'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.removeDownload(_jellyfin('b'));
        // A fresh, explicit request supersedes the pending cancellation, so
        // the request already waiting for a slot goes ahead when it gets one.
        await repository.requestDownload(_jellyfin('b'));
        gate.complete();
        await Future.wait(<Future<void>>[a, b]);

        expect(downloader.fetched.map((t) => t.id), <String>['a', 'b']);
        expect(await repository.statusFor('b'), DownloadStatus.downloaded);
        expect(files.bytesFor('jellyfin_b.mp3'), isNotNull);
      });

      test('re-requesting a download cancelled mid-fetch keeps that fetch',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> first = repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.removeDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j1'));
        gate.complete();
        await first;

        // The bytes already in flight are committed; nothing is fetched twice.
        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
      });

      test('a download asked for again after a cancel shows it downloading',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> first = repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.removeDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        await repository.requestDownload(_jellyfin('j1'));

        // The fetch it went back to is still running, and the row says so.
        expect(await repository.statusFor('j1'), DownloadStatus.downloading);
        gate.complete();
        await first;
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('a removal that lands mid-commit evicts nothing for it', () async {
        final _GatedPreferences gated =
            _GatedPreferences(InMemoryDownloadPreferences());
        await gated.setMaxCacheBytes(4);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: gated,
        );
        await repository.requestDownload(_jellyfin('a'));
        expect(await repository.statusFor('a'), DownloadStatus.downloaded);

        // b only fits by evicting a. Park its commit before it evicts.
        gated.gate = Completer<void>();
        final Future<void> request = repository.requestDownload(_jellyfin('b'));
        await gated.reachedGate.future;
        await repository.removeDownload(_jellyfin('b'));
        gated.gate!.complete();
        await request;
        await _settle();

        expect(await repository.statusFor('a'), DownloadStatus.downloaded);
        expect(files.bytesFor('jellyfin_a.mp3'), isNotNull);
        expect(await repository.statusFor('b'), DownloadStatus.notDownloaded);
        expect(files.bytesFor('jellyfin_b.mp3'), isNull);
        expect(
          (await store.loadDownloads()).map((CachedTrack c) => c.trackId),
          <String>['a'],
        );
      });

      test('a clear that lands mid-commit leaves the row matching the cache',
          () async {
        final _GatedPreferences gated =
            _GatedPreferences(InMemoryDownloadPreferences());
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: gated,
        );

        // Park j1's commit after it has checked for a cancellation.
        gated.gate = Completer<void>();
        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        await gated.reachedGate.future;
        await repository.clearAll();
        gated.gate!.complete();
        await request;

        // Too late to stop the write. Whichever way that goes, the row must
        // agree with what is cached, not hide a committed download.
        final bool cached = (await store.loadDownloads())
            .any((CachedTrack c) => c.trackId == 'j1' && !c.preloaded);
        expect(
          await repository.statusFor('j1'),
          cached ? DownloadStatus.downloaded : DownloadStatus.notDownloaded,
        );
      });

      test('cancelling a download held for Wi-Fi clears its queued row',
          () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = build();
        expect(
          await repository.requestDownload(_jellyfin('j1')),
          DownloadRequestOutcome.waitingForWifi,
        );
        expect(await repository.statusFor('j1'), DownloadStatus.queued);

        await repository.removeDownload(_jellyfin('j1'));

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(downloader.fetchCount, 0);
      });

      test('a cancelled download can be requested again and downloads',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> first = repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.removeDownload(_jellyfin('j1'));
        gate.complete();
        await first;
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);

        // A fresh, explicit request supersedes the prior cancellation.
        await repository.requestDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('clear all during an in-flight download leaves nothing behind',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.clearAll();
        gate.complete();
        await request;

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.downloadedTrackKeys(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        expect((await repository.cacheSnapshot()).usedBytes, 0);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
      });

      test('clear all also stops downloads still waiting for a slot', () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
          scheduler: DownloadScheduler(maxConcurrent: 1),
        );

        final requests = <Future<void>>[
          repository.requestDownload(_jellyfin('a')),
          repository.requestDownload(_jellyfin('b')),
        ];
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.clearAll();
        // Both rows read as cleared right away, not once a's fetch ends.
        expect(await repository.statusFor('a'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('b'), DownloadStatus.notDownloaded);
        gate.complete();
        await Future.wait(requests);

        expect(downloader.fetched.map((t) => t.id), <String>['a']);
        expect(await repository.statusFor('a'), DownloadStatus.notDownloaded);
        expect(await repository.statusFor('b'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
        expect(files.bytesFor('jellyfin_a.mp3'), isNull);
        expect(files.bytesFor('jellyfin_b.mp3'), isNull);
      });

      test('clear all during a fetch that then fails leaves it not downloaded',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await repository.clearAll();
        downloader.error = Exception('boom');
        gate.complete();
        await request;

        // Cleared, so neither "failed" nor stuck at "downloading".
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      });
    });

    group('a download and a pre-cache of the same track', () {
      // Smart pre-cache warms the next tracks while the listener browses, so a
      // download tapped on one of them (or a "Download album" while it plays)
      // often starts while that track's pre-cache is still fetching. Each
      // fetch here has its own gate, so the test picks which lands first.
      late _PerCallDownloader perCall;

      CacheDownloadRepository buildPerCall({OfflineFileStore? fileStore}) {
        perCall = _PerCallDownloader();
        return CacheDownloadRepository(
          store: store,
          files: fileStore ?? files,
          downloader: perCall,
          connectivity: connectivity,
          preferences: preferences,
        );
      }

      /// Starts a pre-cache of j1, then a download of it, and waits until
      /// both are fetching: the pre-cache is fetch 0, the download fetch 1.
      Future<({Future<void> precache, Future<void> download})> bothInFlight(
          CacheDownloadRepository repository) async {
        final Future<void> precache = repository.prefetch(_jellyfin('j1'));
        await _pumpUntil(() => perCall.calls.isNotEmpty);
        final Future<void> download =
            repository.requestDownload(_jellyfin('j1'));
        await _pumpUntil(() => perCall.calls.length >= 2);
        expect(perCall.calls, hasLength(2));
        return (precache: precache, download: download);
      }

      Future<void> expectNothingCached(
          CacheDownloadRepository repository) async {
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await repository.downloadedTrackKeys(), isEmpty);
        expect(await store.loadDownloads(), isEmpty);
        expect((await repository.cacheSnapshot()).usedBytes, 0);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
      }

      test(
          'a download cancelled while the pre-cache ends first stays cancelled',
          () async {
        final repository = buildPerCall();
        final inFlight = await bothInFlight(repository);

        await repository.removeDownload(_jellyfin('j1'));
        perCall.calls[0].complete();
        await inFlight.precache;
        perCall.calls[1].complete();
        await inFlight.download;
        await _settle();

        await expectNothingCached(repository);
      });

      test('a download cancelled while the pre-cache fails stays cancelled',
          () async {
        final repository = buildPerCall();
        final inFlight = await bothInFlight(repository);

        await repository.removeDownload(_jellyfin('j1'));
        perCall.calls[0].fail(Exception('connection reset'));
        await inFlight.precache;
        perCall.calls[1].complete();
        await inFlight.download;
        await _settle();

        await expectNothingCached(repository);
      });

      test('clear all with both in flight leaves nothing, pre-cache last',
          () async {
        final repository = buildPerCall();
        final inFlight = await bothInFlight(repository);

        await repository.clearAll();
        perCall.calls[1].complete();
        await inFlight.download;
        perCall.calls[0].complete();
        await inFlight.precache;
        await _settle();

        await expectNothingCached(repository);
      });

      test('clear all with both in flight leaves nothing, pre-cache first',
          () async {
        final repository = buildPerCall();
        final inFlight = await bothInFlight(repository);

        await repository.clearAll();
        perCall.calls[0].complete();
        await inFlight.precache;
        perCall.calls[1].complete();
        await inFlight.download;
        await _settle();

        await expectNothingCached(repository);
      });

      test('a pre-cache ending does not disturb the download it overlapped',
          () async {
        final repository = buildPerCall();
        final inFlight = await bothInFlight(repository);

        perCall.calls[0].complete();
        await inFlight.precache;
        perCall.calls[1].complete();
        await inFlight.download;

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        final List<CachedTrack> stored = await store.loadDownloads();
        expect(stored, hasLength(1));
        expect(stored.single.preloaded, isFalse);
      });

      test('a download asked for again after a cancel still downloads',
          () async {
        final repository = buildPerCall();
        final inFlight = await bothInFlight(repository);

        await repository.removeDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j1'));
        perCall.calls[0].complete();
        await inFlight.precache;
        perCall.calls[1].complete();
        await inFlight.download;

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
      });
    });

    group('a removal that lands while a download is being written', () {
      test('stays removed and leaves no file behind', () async {
        final gated = _GatedWriteFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: gated,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        await gated.reachedWrite.future;
        await repository.removeDownload(_jellyfin('j1'));
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        gated.release.complete();
        await request;
        await _settle();

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
        expect((await repository.cacheSnapshot()).usedBytes, 0);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
      });

      test('a clear all that lands then leaves nothing behind', () async {
        final gated = _GatedWriteFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: gated,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        await gated.reachedWrite.future;
        await repository.clearAll();
        gated.release.complete();
        await request;
        await _settle();

        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNull);
      });

      test('a re-request made then keeps the download', () async {
        final gated = _GatedWriteFileStore(files);
        final repository = CacheDownloadRepository(
          store: store,
          files: gated,
          downloader: downloader,
          connectivity: connectivity,
          preferences: preferences,
        );

        final Future<void> request =
            repository.requestDownload(_jellyfin('j1'));
        await gated.reachedWrite.future;
        await repository.removeDownload(_jellyfin('j1'));
        await repository.requestDownload(_jellyfin('j1'));
        gated.release.complete();
        await request;

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
        expect(downloader.fetchCount, 1);
      });
    });

    group('downloads held by the network policy', () {
      // A download asked for on mobile data (Wi-Fi only, the default) or
      // while offline is held as "queued", and the offline message promises
      // it starts by itself. These pin that it does, and that nothing it
      // shouldn't start does.
      late StreamController<NetworkStatus> changes;
      String? scope = 'jellyfin:account-a';

      CacheDownloadRepository buildHeld({
        ConnectivityService? connectivityService,
        DownloadPreferences? prefs,
        DownloadScheduler? scheduler,
      }) {
        return CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader,
          connectivity: connectivityService ?? connectivity,
          preferences: prefs ?? preferences,
          scheduler: scheduler,
          networkChanges: changes.stream,
          accountScopeOf: (Track _) => scope,
        );
      }

      setUp(() {
        changes = StreamController<NetworkStatus>.broadcast();
        scope = 'jellyfin:account-a';
      });

      tearDown(() => changes.close());

      Future<void> networkBecomes(NetworkStatus status) async {
        connectivity.status = status;
        changes.add(status);
        await _pumpUntil(() => false);
      }

      test('a download held for Wi-Fi starts when Wi-Fi arrives', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = buildHeld();
        expect(
          await repository.requestDownload(_jellyfin('j1')),
          DownloadRequestOutcome.waitingForWifi,
        );
        expect(await repository.statusFor('j1'), DownloadStatus.queued);
        expect(downloader.fetchCount, 0);

        await networkBecomes(NetworkStatus.wifi);

        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
        expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
      });

      test('a download held while offline starts when the connection is back',
          () async {
        connectivity.status = NetworkStatus.offline;
        final repository = buildHeld();
        expect(
          await repository.requestDownload(_jellyfin('j1')),
          DownloadRequestOutcome.waitingForConnection,
        );

        await networkBecomes(NetworkStatus.wifi);

        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('a held album starts together, each track once', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = buildHeld();
        for (final String id in <String>['a', 'b', 'c']) {
          await repository.requestDownload(_jellyfin(id));
        }

        await networkBecomes(NetworkStatus.wifi);
        await networkBecomes(NetworkStatus.wifi);

        expect(downloader.fetched.map((Track t) => t.id).toList()..sort(),
            <String>['a', 'b', 'c']);
        for (final String id in <String>['a', 'b', 'c']) {
          expect(await repository.statusFor(id), DownloadStatus.downloaded);
        }
      });

      test('a change that still does not allow it leaves it queued', () async {
        connectivity.status = NetworkStatus.offline;
        final repository = buildHeld();
        await repository.requestDownload(_jellyfin('j1'));

        // Back online, but on mobile data with Wi-Fi only.
        await networkBecomes(NetworkStatus.mobile);
        expect(downloader.fetchCount, 0);
        expect(await repository.statusFor('j1'), DownloadStatus.queued);

        // Still held, so the next change can start it.
        await networkBecomes(NetworkStatus.wifi);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('allowing mobile data starts what was held for Wi-Fi', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = buildHeld();
        await repository.requestDownload(_jellyfin('j1'));

        await preferences.setAllowMobileData(true);
        await repository.retryHeldDownloads();

        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('a held download that was cancelled never starts', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = buildHeld();
        await repository.requestDownload(_jellyfin('j1'));
        await repository.removeDownload(_jellyfin('j1'));

        await networkBecomes(NetworkStatus.wifi);

        expect(downloader.fetchCount, 0);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      });

      test('clear all drops held downloads too', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = buildHeld();
        await repository.requestDownload(_jellyfin('j1'));

        await repository.clearAll();
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        await networkBecomes(NetworkStatus.wifi);

        expect(downloader.fetchCount, 0);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      });

      test('a held download whose account changed is dropped, not fetched',
          () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = buildHeld();
        await repository.requestDownload(_jellyfin('j1'));

        // Signed in as someone else (or signed out) while it waited: the
        // session there now would fetch another account's item as j1.
        scope = 'jellyfin:account-b';
        await networkBecomes(NetworkStatus.wifi);

        expect(downloader.fetchCount, 0);
        expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('a download waiting for a slot when its account changes is dropped',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository =
            buildHeld(scheduler: DownloadScheduler(maxConcurrent: 1));

        final requests = <Future<void>>[
          repository.requestDownload(_jellyfin('a')),
          repository.requestDownload(_jellyfin('b')),
        ];
        await _pumpUntil(() => downloader.fetchCount >= 1);
        scope = null; // signed out
        gate.complete();
        await Future.wait(requests);

        expect(downloader.fetched.map((Track t) => t.id), <String>['a']);
        expect(await repository.statusFor('b'), DownloadStatus.notDownloaded);
      });

      test('a connection change that lands while it is being decided counts',
          () async {
        final gated = _GatedConnectivity(NetworkStatus.mobile);
        final repository = buildHeld(connectivityService: gated);

        // The policy is asked while on mobile data; Wi-Fi arrives before the
        // answer does, so the change finds nothing held yet.
        gated.gate = Completer<void>();
        final Future<DownloadRequestOutcome> request =
            repository.requestDownload(_jellyfin('j1'));
        await gated.reached.future;
        gated.status = NetworkStatus.wifi;
        changes.add(NetworkStatus.wifi);
        await _pumpUntil(() => false);
        gated.gate!.complete();
        expect(await request, DownloadRequestOutcome.waitingForWifi);
        await _pumpUntil(() => downloader.fetchCount >= 1);
        await _pumpUntil(() => false);

        expect(downloader.fetchCount, 1);
        expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      });

      test('a held download that no longer fits says it failed', () async {
        connectivity.status = NetworkStatus.mobile;
        await preferences.setMaxCacheBytes(2);
        final repository = buildHeld();
        await repository.requestDownload(_jellyfin('j1'));

        await networkBecomes(NetworkStatus.wifi);

        // Nobody is watching a snackbar for a download that started on its
        // own: the row offers Retry, which explains the cache limit.
        expect(await repository.statusFor('j1'), DownloadStatus.failed);
        expect(await store.loadDownloads(), isEmpty);
      });

      test('nothing is held after the repository is disposed', () async {
        connectivity.status = NetworkStatus.mobile;
        final repository = buildHeld();
        await repository.requestDownload(_jellyfin('j1'));
        await repository.dispose();

        connectivity.status = NetworkStatus.wifi;
        changes.add(NetworkStatus.wifi);
        await _pumpUntil(() => false);
        await repository.retryHeldDownloads();

        expect(downloader.fetchCount, 0);
      });
    });

    group('preload concurrency', () {
      test('two concurrent prefetches of the same track fetch its bytes once',
          () async {
        final gate = Completer<void>();
        downloader = _FakeRemoteDownloader(gate: gate.future);
        final repository = build();

        final Future<void> p1 = repository.prefetch(_jellyfin('j1'));
        final Future<void> p2 = repository.prefetch(_jellyfin('j1'));
        await _pumpUntil(() => downloader.fetchCount >= 1);
        gate.complete();
        await Future.wait(<Future<void>>[p1, p2]);

        // The reservation made the second prefetch bail before fetching, so the
        // bytes were pulled exactly once (not just de-duplicated at commit).
        expect(downloader.fetchCount, 1);
      });
    });
  });

  group('CacheDownloadRepository — Plex tracks (provider-aware caching)', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _FakeRemoteDownloader plexDownloader;

    CacheDownloadRepository build({RemoteTrackDownloader? downloader}) =>
        CacheDownloadRepository(
          store: store,
          files: files,
          downloader: downloader ?? plexDownloader,
          connectivity: connectivity,
          preferences: preferences,
        );

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      preferences = InMemoryDownloadPreferences();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      plexDownloader = _FakeRemoteDownloader(schemes: const <String>['plex:']);
    });

    Track plex(String id) => Track(id: id, title: id, uri: 'plex:$id');

    test('downloads a Plex track and tags the persisted entry as plex',
        () async {
      final repo = build();

      final outcome = await repo.requestDownload(plex('101'));

      expect(outcome, DownloadRequestOutcome.started);
      expect(await repo.statusFor('101'), DownloadStatus.downloaded);
      // Bytes are stored under the non-secret ratingKey id; no token anywhere.
      expect(files.bytesFor('plex_101.mp3'), _FakeRemoteDownloader.bytes);
      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.trackId, '101');
      expect(saved.single.fileName, 'plex_101.mp3');
      // The source type marks it as Plex — how the cache stays provider-aware.
      expect(saved.single.sourceType, 'plex');
    });

    test('a cached Plex track survives a restart (metadata persists)',
        () async {
      await build().requestDownload(plex('101'));

      // A fresh repository over the same durable stores re-loads the download.
      final reborn = build();
      expect(await reborn.statusFor('101'), DownloadStatus.downloaded);
      final snapshot = await reborn.cacheSnapshot();
      expect(
        snapshot.entries.map((CachedTrack e) => e.trackId),
        contains('101'),
      );
    });

    test('removing a cached Plex track deletes its file and clears status',
        () async {
      final repo = build();
      await repo.requestDownload(plex('101'));
      expect(files.bytesFor('plex_101.mp3'), isNotNull);

      await repo.removeDownload(plex('101'));

      expect(await repo.statusFor('101'), DownloadStatus.notDownloaded);
      expect(files.bytesFor('plex_101.mp3'), isNull);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('a failed Plex fetch marks it failed and caches nothing', () async {
      // A cache failure must not break streaming: the track is simply marked
      // failed (offering retry) and no file/metadata is written, so playback
      // streams normally when the track is reached.
      plexDownloader.error = StateError('Plex download failed.');
      final repo = build();

      await repo.requestDownload(plex('101'));

      expect(await repo.statusFor('101'), DownloadStatus.failed);
      expect(files.bytesFor('plex_101.mp3'), isNull);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('Plex and Jellyfin copies cache independently — no cross-conflict',
        () async {
      // One downloader that claims both providers, so both tracks cache through
      // the same repository. They must persist as two distinct, correctly-tagged
      // entries — a Plex cache can never shadow or evict a Jellyfin one.
      final both = _FakeRemoteDownloader(
        schemes: const <String>['plex:', 'jellyfin:'],
      );
      final repo = build(downloader: both);

      await repo.requestDownload(plex('101'));
      await repo.requestDownload(_jellyfin('j1'));

      expect(await repo.statusFor('101'), DownloadStatus.downloaded);
      expect(await repo.statusFor('j1'), DownloadStatus.downloaded);
      final saved = await store.loadDownloads();
      final byId = <String, CachedTrack>{
        for (final CachedTrack c in saved) c.trackId: c,
      };
      expect(byId['101']!.sourceType, 'plex');
      expect(byId['j1']!.sourceType, 'jellyfin');
      expect(byId['101']!.fileName, 'plex_101.mp3');
      expect(byId['j1']!.fileName, 'jellyfin_j1.mp3');
      expect(files.bytesFor('plex_101.mp3'), isNotNull);
      expect(files.bytesFor('jellyfin_j1.mp3'), isNotNull);
    });

    test('Plex and Jellyfin tracks that share a catalog id never conflict',
        () async {
      // The hard case the catalog's id-uniqueness can't guarantee on its own:
      // two providers expose the SAME local id ("101"). The cache must keep them
      // fully independent — distinct files, distinct metadata, correct
      // resolution, and isolated removal — so a Plex cache can never shadow,
      // overwrite, or remove another provider's copy.
      final both = _FakeRemoteDownloader(
        schemes: const <String>['plex:', 'jellyfin:'],
      );
      final repo = build(downloader: both);
      final locator = StoreCachedTrackLocator(store, files);

      const Track plex101 = Track(id: '101', title: 'P', uri: 'plex:101');
      const Track jelly101 = Track(id: '101', title: 'J', uri: 'jellyfin:101');

      await repo.requestDownload(plex101);
      // The shared id must NOT make the second look already-downloaded.
      await repo.requestDownload(jelly101);

      // Both were actually fetched and cached.
      expect(
        both.fetched.map((Track t) => t.uri).toSet(),
        <String>{'plex:101', 'jellyfin:101'},
      );

      // Two distinct persisted entries, each tagged by its provider, written to
      // distinct, provider-namespaced files (the token-free id is namespaced).
      final saved = await store.loadDownloads();
      expect(saved, hasLength(2));
      final plexEntry =
          saved.firstWhere((CachedTrack c) => c.sourceType == 'plex');
      final jellyEntry =
          saved.firstWhere((CachedTrack c) => c.sourceType == 'jellyfin');
      expect(plexEntry.trackId, '101');
      expect(jellyEntry.trackId, '101');
      expect(plexEntry.fileName, 'plex_101.mp3');
      expect(jellyEntry.fileName, 'jellyfin_101.mp3');
      expect(plexEntry.fileName, isNot(jellyEntry.fileName));

      // Each resolves to its OWN cached file — no shadowing across providers.
      final plexPath = await locator.cachedFilePath(plex101);
      final jellyPath = await locator.cachedFilePath(jelly101);
      expect(plexPath, isNotNull);
      expect(jellyPath, isNotNull);
      expect(plexPath, isNot(jellyPath));

      // Removing the Plex copy leaves the Jellyfin copy fully intact.
      await repo.removeDownload(plex101);
      expect(await locator.cachedFilePath(plex101), isNull);
      expect(await locator.cachedFilePath(jelly101), jellyPath);
      final remaining = await store.loadDownloads();
      expect(remaining, hasLength(1));
      expect(remaining.single.sourceType, 'jellyfin');
      expect(files.bytesFor('plex_101.mp3'), isNull);
      expect(files.bytesFor('jellyfin_101.mp3'), isNotNull);
    });
  });

  // Smart cleanup is one shared, provider-agnostic policy: every offline-capable
  // remote provider (Plex, Jellyfin, Subsonic/Navidrome) caches through the same
  // repository and is evicted by the same LRU rules — keyed by the provider-aware
  // (sourceType, trackId) identity so same-id tracks never shadow or evict each
  // other. These tests drive one repository whose downloader claims all three.
  group('CacheDownloadRepository — provider-agnostic smart cleanup', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _FakeRemoteDownloader downloader;

    // A clock that advances one minute per call, so least-recently-used ordering
    // is deterministic across providers.
    DateTime Function() incrementingClock() {
      int tick = 0;
      return () => DateTime(2024, 1, 1).add(Duration(minutes: tick++));
    }

    CacheDownloadRepository buildLimited({
      required int maxBytes,
      Track? Function()? currentlyPlaying,
      DateTime Function()? now,
    }) {
      preferences = InMemoryDownloadPreferences(maxCacheBytes: maxBytes);
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
        currentlyPlayingTrack: currentlyPlaying,
        now: now,
      );
    }

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      downloader = _FakeRemoteDownloader(
        schemes: const <String>['plex:', 'jellyfin:', 'subsonic:'],
      );
    });

    test('a Subsonic/Navidrome track is evicted like any other provider',
        () async {
      final repo = buildLimited(maxBytes: 10, now: incrementingClock());

      await repo.requestDownload(_subsonic('s1')); // oldest
      await repo.requestDownload(_subsonic('s2'));
      await repo.requestDownload(_subsonic('s3')); // forces eviction

      expect(await repo.statusFor('s1'), DownloadStatus.notDownloaded);
      expect(await repo.statusFor('s2'), DownloadStatus.downloaded);
      expect(await repo.statusFor('s3'), DownloadStatus.downloaded);
      expect(files.bytesFor('subsonic_s1.mp3'), isNull);
    });

    test('eviction ranks Plex, Jellyfin, and Subsonic together as one LRU list',
        () async {
      // Room for three 4-byte tracks; a fourth evicts the least-recently-used
      // across ALL providers (the plex track cached first).
      final repo = buildLimited(maxBytes: 12, now: incrementingClock());

      await repo.requestDownload(_plex('a')); // oldest, across providers
      await repo.requestDownload(_jellyfin('b'));
      await repo.requestDownload(_subsonic('c'));
      await repo.requestDownload(_jellyfin('d')); // forces one eviction

      expect(await repo.statusFor('a'), DownloadStatus.notDownloaded);
      expect(await repo.statusFor('b'), DownloadStatus.downloaded);
      expect(await repo.statusFor('c'), DownloadStatus.downloaded);
      expect(await repo.statusFor('d'), DownloadStatus.downloaded);
      expect(files.bytesFor('plex_a.mp3'), isNull);
    });

    test('a recently played cross-provider track is kept; a stale one evicted',
        () async {
      final repo = buildLimited(maxBytes: 12, now: incrementingClock());

      await repo.requestDownload(_plex('a')); // oldest
      await repo.requestDownload(_jellyfin('b'));
      await repo.requestDownload(_subsonic('c'));
      // Replaying the oldest (Plex 'a') makes the Jellyfin 'b' the LRU now.
      await repo.notePlayed(_plex('a'));
      await repo.requestDownload(_subsonic('d')); // forces one eviction

      expect(await repo.statusFor('a'), DownloadStatus.downloaded); // refreshed
      expect(await repo.statusFor('b'), DownloadStatus.notDownloaded); // stale
      expect(await repo.statusFor('c'), DownloadStatus.downloaded);
      expect(await repo.statusFor('d'), DownloadStatus.downloaded);
    });

    test('a download evicts a same-id track from another provider (no shadow)',
        () async {
      // The exact same-id collision: subsonic:101 is cached and is the only
      // evictable track; downloading plex:101 (same catalog id, different
      // provider) must EVICT it to fit — never treat it as the incoming track's
      // own old copy and silently overshoot the limit.
      final repo = buildLimited(maxBytes: 4, now: incrementingClock());

      await repo.requestDownload(_subsonic('101'));
      expect(await repo.statusFor('101'), DownloadStatus.downloaded);

      final outcome = await repo.requestDownload(_plex('101'));
      expect(outcome, DownloadRequestOutcome.started);

      // subsonic:101 gave way; plex:101 is the lone copy and the limit held.
      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.sourceType, 'plex');
      expect(files.bytesFor('subsonic_101.mp3'), isNull);
      expect(files.bytesFor('plex_101.mp3'), isNotNull);
      expect((await repo.cacheSnapshot()).usedBytes, 4);
    });

    test('the playing track is protected per-provider, not by bare id',
        () async {
      // plex:101 is playing; a jellyfin:101 with the SAME id is a different
      // track and must stay evictable — only the playing provider's copy is safe.
      final repo = buildLimited(
        maxBytes: 8,
        currentlyPlaying: () => _plex('101'),
        now: incrementingClock(),
      );

      await repo.requestDownload(_plex('101')); // playing
      await repo.requestDownload(_jellyfin('101')); // same id, other provider
      await repo.requestDownload(_subsonic('x')); // full → forces one eviction

      final Set<String?> sources =
          (await store.loadDownloads()).map((c) => c.sourceType).toSet();
      expect(sources, containsAll(<String>['plex', 'subsonic']));
      // The same-id, non-playing Jellyfin copy was evicted, not the playing one.
      expect(sources, isNot(contains('jellyfin')));
      expect(files.bytesFor('plex_101.mp3'), isNotNull);
      expect(files.bytesFor('jellyfin_101.mp3'), isNull);
    });

    test('pre-cache continues after cleanup frees cross-provider space',
        () async {
      // A Jellyfin pre-cache fills the cache; a Plex pre-cache then evicts it
      // (pre-cached entries are sacrificed first) and caches itself — pre-cache
      // resumes after cleanup, and the limit holds.
      final repo = buildLimited(maxBytes: 4, now: incrementingClock());

      await repo.prefetch(_jellyfin('old'));
      expect((await store.loadDownloads()).single.trackId, 'old');

      await repo.prefetch(_plex('new'));

      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.sourceType, 'plex');
      expect(saved.single.trackId, 'new');
      expect(saved.single.preloaded, isTrue);
      expect((await repo.cacheSnapshot()).usedBytes, 4);
    });

    test('pre-cache is skipped safely when cleanup cannot free enough',
        () async {
      // The cache is full of a pinned download (never evictable). A pre-cache
      // must skip rather than break — no fetch, no throw, nothing cached.
      final repo = buildLimited(maxBytes: 4, now: incrementingClock());
      await repo.requestDownload(_jellyfin('pinned'));
      await repo.setPinned(_jellyfin('pinned'), true);

      await repo.prefetch(_plex('want')); // no room, nothing safe to evict

      final saved = await store.loadDownloads();
      expect(saved, hasLength(1));
      expect(saved.single.trackId, 'pinned');
      expect(
          downloader.fetched.any((Track t) => t.uri == 'plex:want'), isFalse);
      expect((await repo.cacheSnapshot()).usedBytes, 4);
    });
  });

  // Issue #356: "disable song cache". Automatic song caching has exactly one
  // gate — DownloadPreferences.preloadEnabled — surfaced in Settings as
  // "Pre-cache upcoming tracks" and consulted only by SmartPrecacheService
  // (see its own tests for that unit-level guarantee). These tests close the
  // loop end-to-end against a *real* repository: turning it off truly writes
  // no bytes, streaming still resolves normally, and explicit downloads (which
  // never consult this preference) are unaffected.
  group('automatic song caching can be disabled (issue #356)', () {
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;
    late _FakeConnectivity connectivity;
    late _FakeRemoteDownloader downloader;

    CacheDownloadRepository build() {
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: preferences,
      );
    }

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      preferences = InMemoryDownloadPreferences(preloadEnabled: false);
      connectivity = _FakeConnectivity(NetworkStatus.wifi);
      downloader = _FakeRemoteDownloader();
    });

    test(
        'SmartPrecacheService caches nothing through a real repository when '
        'preloadEnabled is off', () async {
      final CacheDownloadRepository repo = build();
      final StreamController<PlaybackState> states =
          StreamController<PlaybackState>.broadcast();
      final SmartPrecacheService service = SmartPrecacheService(
        playbackStates: states.stream,
        prefetcher: repo,
        preferences: preferences,
      );

      states.add(const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: Track(id: 'now', title: 'now', uri: 'jellyfin:now'),
        upNext: <Track>[
          Track(id: 'next1', title: 'next1', uri: 'jellyfin:next1'),
          Track(id: 'next2', title: 'next2', uri: 'jellyfin:next2'),
        ],
      ));
      await _settle();
      await _settle();

      expect(downloader.fetchCount, 0);
      expect((await repo.cacheSnapshot()).entries, isEmpty);
      expect(await repo.downloadedTrackKeys(), isEmpty);

      await service.dispose();
      await states.close();
    });

    test('explicit downloads remain enabled when preloadEnabled is off',
        () async {
      final CacheDownloadRepository repo = build();

      final DownloadRequestOutcome outcome =
          await repo.requestDownload(_jellyfin('manual'));

      expect(outcome, DownloadRequestOutcome.started);
      expect(await repo.statusFor('manual'), DownloadStatus.downloaded);
      expect(downloader.fetchCount, 1);
    });

    test(
        'streaming still resolves via the fallback when nothing is cached '
        '(song caching disabled)', () async {
      // Nothing was ever downloaded or preloaded — store/files stay empty for
      // this test, exactly what an all-session-long preloadEnabled:false user
      // sees for a track they never explicitly downloaded.
      final StoreCachedTrackLocator locator =
          StoreCachedTrackLocator(store, files);
      final _RecordingStreamResolver fallback = _RecordingStreamResolver();
      final OfflineFirstPlayableUriResolver resolver =
          OfflineFirstPlayableUriResolver(
        locator: locator,
        fallback: fallback,
      );
      final Track track = _jellyfin('unplayed');

      final ResolvedPlayable resolved = await resolver.resolve(track);

      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(fallback.resolved, track);
    });
  });

  group('a server error document is never cached as the track', () {
    // End to end through the real Subsonic downloader: download.view refuses
    // with HTTP 200 and a subsonic-response error document. Were it cached,
    // the offline-first resolver would serve it ahead of the stream and every
    // play would fail.
    late InMemoryDownloadStore store;
    late InMemoryOfflineFileStore files;
    late InMemoryDownloadPreferences preferences;

    CacheDownloadRepository build() {
      final MockClient server = MockClient((http.Request request) async {
        return http.Response(
          '{"subsonic-response":{"status":"failed","version":"1.16.1",'
          '"error":{"code":70,"message":"The requested data was not found"}}}',
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      return CacheDownloadRepository(
        store: store,
        files: files,
        downloader: SubsonicTrackDownloader(
          () => _SubsonicDownloadSource(),
          httpClient: server,
        ),
        connectivity: _FakeConnectivity(NetworkStatus.wifi),
        preferences: preferences,
      );
    }

    Future<ResolvedPlayable> resolve(Track track) =>
        OfflineFirstPlayableUriResolver(
          locator: StoreCachedTrackLocator(store, files),
          fallback: _RecordingStreamResolver(),
        ).resolve(track);

    setUp(() {
      store = InMemoryDownloadStore();
      files = InMemoryOfflineFileStore();
      preferences = InMemoryDownloadPreferences();
    });

    test('an explicit download fails and stores nothing', () async {
      final CacheDownloadRepository repo = build();

      await repo.requestDownload(_subsonic('s1'));

      expect(await repo.statusFor('s1'), DownloadStatus.failed);
      expect(await store.loadDownloads(), isEmpty);
      expect(files.bytesFor('subsonic_s1'), isNull);
      expect(
        (await resolve(_subsonic('s1'))).source,
        PlaybackSource.streamingDirect,
      );
    });

    test('a pre-cache caches nothing', () async {
      final CacheDownloadRepository repo = build();

      await repo.prefetch(_subsonic('s1'));

      expect(await repo.statusFor('s1'), DownloadStatus.notDownloaded);
      expect(await store.loadDownloads(), isEmpty);
      expect(files.bytesFor('subsonic_s1'), isNull);
      expect(
        (await resolve(_subsonic('s1'))).source,
        PlaybackSource.streamingDirect,
      );
    });
  });
}

/// A signed-in Subsonic connection that always mints the same download URL,
/// so the real [SubsonicTrackDownloader] can run against a [MockClient].
class _SubsonicDownloadSource implements SubsonicStreamSource {
  static final Uri _download = Uri.parse(
    'https://music.example.com/rest/download.view?id=s1&t=token&s=salt',
  );

  @override
  Future<void> verifyReachable() async {}

  @override
  Future<Uri?> resolvePlayableUri(Track track) async => _download;

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => _download;
}

/// Lets the broadcast stream deliver any pending events.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Pumps event-loop turns until [condition] holds (or a bounded number elapse),
/// so concurrency assertions don't depend on exact async scheduling.
Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
