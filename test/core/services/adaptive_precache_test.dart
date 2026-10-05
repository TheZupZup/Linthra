import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/offline_first_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/services/smart_precache_service.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';

/// Smart pre-cache driven end to end: the real service over the real cache
/// repository, with only the network (downloader, connectivity) faked. What is
/// asserted is what a listener would notice: which tracks got fetched, in what
/// order, what is on disk afterwards, and what still plays offline.

class _Connectivity implements ConnectivityService {
  _Connectivity(this.status);

  NetworkStatus status;
  final StreamController<NetworkStatus> _changes =
      StreamController<NetworkStatus>.broadcast();

  /// Changes the reported status and announces it, like the platform would.
  void change(NetworkStatus next) {
    status = next;
    _changes.add(next);
  }

  @override
  Stream<NetworkStatus> get statusStream => _changes.stream;

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// Returns four canned bytes per track (or what [sizes] says), streamed in
/// four-byte chunks with progress reported like the real downloaders: a
/// progress callback that throws stops the download there. A test can hold
/// any track's fetch open with [holdNext] to act while it is in flight.
class _Downloader implements RemoteTrackDownloader {
  static const int size = 4;

  final List<String> fetched = <String>[];

  /// Tracks whose bytes were pulled in full.
  final List<String> finished = <String>[];
  final Map<String, int> sizes = <String, int>{};
  final Map<String, Completer<void>> _held = <String, Completer<void>>{};

  /// Holds the next fetch of [uri] until the returned completer completes.
  Completer<void> holdNext(String uri) => _held[uri] = Completer<void>();

  @override
  bool isRemote(Track track) => !track.uri.startsWith('/');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    fetched.add(track.uri);
    final Completer<void>? held = _held.remove(track.uri);
    if (held != null) await held.future;
    final int total = sizes[track.uri] ?? size;
    onProgress?.call(0, total);
    for (int received = size;; received += size) {
      final int now = received < total ? received : total;
      onProgress?.call(now, total);
      if (now == total) break;
    }
    finished.add(track.uri);
    return RemoteTrackData(
      bytes: List<int>.filled(total, 7),
      fileExtension: 'mp3',
    );
  }
}

/// Writes through to an in-memory store, but can hold a write open after the
/// bytes land (or a delete before it happens), so a test can act while a
/// commit is still saving them or making room.
class _HeldWrites implements OfflineFileStore {
  _HeldWrites(this._inner);

  final InMemoryOfflineFileStore _inner;
  Completer<void>? _hold;
  Completer<void>? _holdDelete;

  /// The base name of every file written, in order.
  final List<String> written = <String>[];

  Completer<void> holdNextWrite() => _hold = Completer<void>();

  Completer<void> holdNextDelete() => _holdDelete = Completer<void>();

  @override
  Future<OfflineFileDraft> createDraft(String trackId) async =>
      _HookedDraft(await _inner.createDraft(trackId), () async {
        written.add(trackId);
        final Completer<void>? hold = _hold;
        _hold = null;
        if (hold != null) await hold.future;
      });

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) => _inner.sizeFor(fileName);

  @override
  Future<void> delete(String fileName) async {
    final Completer<void>? hold = _holdDelete;
    _holdDelete = null;
    if (hold != null) await hold.future;
    await _inner.delete(fileName);
  }

  @override
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  }) =>
      _inner.removeAbandoned(referenced, temporaryOnly: temporaryOnly);
}

/// A draft that runs [_onPublished] once its inner draft is published, before
/// publish returns: the moment a commit has written the file and not yet
/// recorded it.
class _HookedDraft implements OfflineFileDraft {
  _HookedDraft(this._inner, this._onPublished);

  final OfflineFileDraft _inner;
  final Future<void> Function() _onPublished;

  @override
  int get length => _inner.length;

  @override
  Future<void> add(List<int> chunk) => _inner.add(chunk);

  @override
  Future<String> publish({String? extension}) async {
    final String name = await _inner.publish(extension: extension);
    await _onPublished();
    return name;
  }

  @override
  Future<void> discard() => _inner.discard();
}

/// A streaming source that is always unreachable: the device is offline.
class _OfflineStreams implements PlayableUriResolver {
  final List<String> asked = <String>[];

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    asked.add(track.uri);
    throw const PlaybackResolutionException(
      'You appear to be offline.',
      kind: PlaybackResolutionErrorKind.serverUnreachable,
    );
  }
}

Track _t(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

PlaybackState _playing(
  Track current,
  List<Track> upNext, {
  bool shuffle = false,
}) =>
    PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: current,
      upNext: upNext,
      shuffleEnabled: shuffle,
    );

Future<void> _settle() async {
  for (int i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late InMemoryDownloadStore store;
  late InMemoryOfflineFileStore files;
  late _Connectivity connectivity;
  late _Downloader downloader;
  late StreamController<PlaybackState> states;
  String? account;
  Track? playing;

  setUp(() {
    store = InMemoryDownloadStore();
    files = InMemoryOfflineFileStore();
    connectivity = _Connectivity(NetworkStatus.wifi);
    downloader = _Downloader();
    states = StreamController<PlaybackState>.broadcast();
    account = 'jellyfin:account-1';
    playing = null;
  });

  tearDown(() => states.close());

  CacheDownloadRepository repository({
    int maxBytes = 1 << 20,
    OfflineFileStore? over,
  }) =>
      CacheDownloadRepository(
        store: store,
        files: over ?? files,
        downloader: downloader,
        connectivity: connectivity,
        preferences: InMemoryDownloadPreferences(maxCacheBytes: maxBytes),
        currentlyPlayingTrack: () => playing,
      );

  SmartPrecacheService service(
    CacheDownloadRepository repo, {
    int count = 3,
    bool enabled = true,
  }) {
    final SmartPrecacheService service = SmartPrecacheService(
      playbackStates: states.stream,
      prefetcher: repo,
      preferences: InMemoryDownloadPreferences(
        precacheCount: count,
        preloadEnabled: enabled,
      ),
      networkChanges: connectivity.statusStream,
      sessionScopeOf: (Track _) => account,
    );
    addTearDown(service.dispose);
    return service;
  }

  /// Plays [state]: tells the cache what's playing and emits it.
  Future<void> play(PlaybackState state) async {
    playing = state.currentTrack;
    states.add(state);
    await _settle();
  }

  Future<Set<String>> cachedIds() async => <String>{
        for (final CachedTrack c in await store.loadDownloads()) c.trackId,
      };

  group('follows the real queue', () {
    test('warms the next tracks in play order, never the whole queue',
        () async {
      service(repository());

      await play(_playing(
        _t('a'),
        <Track>[for (int i = 0; i < 5000; i++) _t('q$i')],
      ));

      expect(downloader.fetched,
          <String>['jellyfin:q0', 'jellyfin:q1', 'jellyfin:q2']);
    });

    test('follows the shuffled order, not the album order', () async {
      service(repository(), count: 2);

      // Album order is A B C D; the controller shuffled it to A D B C.
      await play(_playing(
        _t('A'),
        <Track>[_t('D'), _t('B'), _t('C')],
        shuffle: true,
      ));

      expect(downloader.fetched, <String>['jellyfin:D', 'jellyfin:B']);
    });

    test('a replaced queue stops the old pass after the fetch in flight',
        () async {
      final CacheDownloadRepository repo = repository();
      service(repo);
      final Completer<void> x1 = downloader.holdNext('jellyfin:x1');

      await play(_playing(_t('x0'), <Track>[_t('x1'), _t('x2'), _t('x3')]));
      // A new album starts while x1 is still downloading.
      await play(_playing(_t('y0'), <Track>[_t('y1'), _t('y2'), _t('y3')]));
      x1.complete();
      await _settle();

      expect(downloader.fetched, <String>[
        'jellyfin:x1',
        'jellyfin:y1',
        'jellyfin:y2',
        'jellyfin:y3',
      ]);
      // The fetch that was already done is kept, not thrown away and redone.
      expect(await cachedIds(), containsAll(<String>['x1', 'y1', 'y2', 'y3']));
    });

    test('Play Next jumps the warm order; Add to Queue past it changes nothing',
        () async {
      service(repository(), count: 2);

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      expect(downloader.fetched, <String>['jellyfin:b', 'jellyfin:c']);

      // Play Next: 'n' now plays right after 'a'.
      await play(
          _playing(_t('a'), <Track>[_t('n'), _t('b'), _t('c'), _t('d')]));
      expect(downloader.fetched,
          <String>['jellyfin:b', 'jellyfin:c', 'jellyfin:n']);

      // Add to Queue: 'z' lands far behind the window.
      await play(_playing(
        _t('a'),
        <Track>[_t('n'), _t('b'), _t('c'), _t('d'), _t('z')],
      ));
      expect(downloader.fetched,
          <String>['jellyfin:b', 'jellyfin:c', 'jellyfin:n']);
    });

    test('a change behind a long run of one repeated track is still seen',
        () async {
      service(repository(), count: 2);
      final List<Track> repeated = <Track>[
        for (int i = 0; i < 250; i++) _t('same'),
      ];

      await play(_playing(_t('now'), <Track>[...repeated, _t('b')]));
      expect(downloader.fetched, <String>['jellyfin:same', 'jellyfin:b']);

      // The first 250 entries are unchanged, but what gets warmed is not.
      await play(_playing(_t('now'), <Track>[...repeated, _t('c')]));
      expect(downloader.fetched.last, 'jellyfin:c');
    });

    test('an already cached track is not downloaded again', () async {
      final CacheDownloadRepository repo = repository();
      await repo.requestDownload(_t('c')); // the user's own download
      downloader.fetched.clear();
      service(repo);

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      // Advancing keeps b..d in the window; none are fetched a second time.
      await play(_playing(_t('b'), <Track>[_t('c'), _t('d')]));

      expect(downloader.fetched, <String>['jellyfin:b', 'jellyfin:d']);
    });

    test('with automatic caching off, nothing is fetched', () async {
      service(repository(), enabled: false);

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c')]));

      expect(downloader.fetched, isEmpty);
    });
  });

  group('network loss and recovery', () {
    test('pre-cached upcoming tracks still play with the network gone',
        () async {
      service(repository());
      await play(_playing(_t('a'), <Track>[_t('b'), _t('c')]));

      connectivity.change(NetworkStatus.offline);
      await _settle();
      // Playback moves on while offline: nothing is fetched or evicted.
      await play(_playing(_t('b'), <Track>[_t('c'), _t('d')]));
      expect(downloader.fetched, <String>['jellyfin:b', 'jellyfin:c']);

      final _OfflineStreams streams = _OfflineStreams();
      final OfflineFirstPlayableUriResolver resolver =
          OfflineFirstPlayableUriResolver(
        locator: StoreCachedTrackLocator(store, files),
        fallback: streams,
      );

      expect((await resolver.resolve(_t('b'))).source,
          PlaybackSource.offlineCache);
      expect((await resolver.resolve(_t('c'))).source,
          PlaybackSource.offlineCache);
      // No provider was asked for either of them.
      expect(streams.asked, isEmpty);
      // The one that never got cached is honestly unavailable.
      await expectLater(
        resolver.resolve(_t('d')),
        throwsA(isA<PlaybackResolutionException>()),
      );
    });

    test('recovery warms the current queue, not the one from before', () async {
      connectivity.status = NetworkStatus.offline;
      service(repository());

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      await play(_playing(_t('x'), <Track>[_t('y'), _t('z')]));
      expect(downloader.fetched, isEmpty);

      connectivity.change(NetworkStatus.wifi);
      await _settle();

      expect(downloader.fetched, <String>['jellyfin:y', 'jellyfin:z']);
    });

    test('moving from metered data to Wi-Fi resumes a Wi-Fi-only cache',
        () async {
      connectivity.status = NetworkStatus.mobile;
      service(repository());

      await play(_playing(_t('a'), <Track>[_t('b')]));
      expect(downloader.fetched, isEmpty);

      connectivity.change(NetworkStatus.wifi);
      await _settle();

      expect(downloader.fetched, <String>['jellyfin:b']);
    });
  });

  group('cleanup', () {
    test('obsolete pre-caches give way to the current queue', () async {
      // Room for three 4-byte tracks.
      service(repository(maxBytes: 12));
      await play(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      expect(await cachedIds(), <String>{'b', 'c', 'd'});

      await play(_playing(_t('x'), <Track>[_t('y'), _t('z')]));

      final Set<String> cached = await cachedIds();
      expect(cached, containsAll(<String>['y', 'z']));
      expect(cached, hasLength(3));
    });

    test('under a tight limit the next track wins over one further on',
        () async {
      // Room for one track, already holding a copy of 'd'.
      service(repository(maxBytes: 4), count: 2);
      await play(_playing(_t('a'), <Track>[_t('d')]));
      expect(await cachedIds(), <String>{'d'});

      // Now 'b' plays before 'd': it gets the room.
      await play(_playing(_t('a2'), <Track>[_t('b'), _t('d')]));

      expect(await cachedIds(), <String>{'b'});
    });

    test('a fetch the queue moved past never evicts what plays next now',
        () async {
      // Room for one track, holding a copy of 'b'.
      service(repository(maxBytes: 4), count: 1);
      await play(_playing(_t('a'), <Track>[_t('b')]));
      expect(await cachedIds(), <String>{'b'});

      // A new queue wants 'c'; while it downloads, the queue changes again
      // and 'b' is next once more.
      final Completer<void> fetchingC = downloader.holdNext('jellyfin:c');
      await play(_playing(_t('a2'), <Track>[_t('c')]));
      await play(_playing(_t('a3'), <Track>[_t('b')]));
      fetchingC.complete();
      await _settle();

      // 'c' would only fit by evicting 'b', which plays next now, so it's
      // dropped and 'b' never has to be fetched again.
      expect(await cachedIds(), <String>{'b'});
      expect(downloader.fetched, <String>['jellyfin:b', 'jellyfin:c']);
    });

    test('a fetch the queue moved past stops making room once it has',
        () async {
      // Room for two songs, holding 'b' and 'c'.
      final _HeldWrites held = _HeldWrites(files);
      service(repository(maxBytes: 8, over: held), count: 2);
      await play(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      expect(await cachedIds(), <String>{'b', 'c'});

      // A long track next needs both gone. The queue goes back to 'b' and 'c'
      // while the first of them is being deleted.
      downloader.sizes['jellyfin:long'] = 8;
      final Completer<void> deleting = held.holdNextDelete();
      await play(_playing(_t('a2'), <Track>[_t('long')]));
      await play(_playing(_t('a3'), <Track>[_t('b'), _t('c')]));
      deleting.complete();
      await _settle();

      // Only the one already being deleted went, and 'long' was never
      // written, so a single song had to be fetched again.
      expect(await cachedIds(), <String>{'b', 'c'});
      expect(downloader.fetched, hasLength(4));
      expect(held.written, isNot(contains('jellyfin_long')));
    });

    test('room made for a queue that moved on is left for the new one',
        () async {
      // Room for one song, holding 'b'.
      final _HeldWrites held = _HeldWrites(files);
      service(repository(maxBytes: 4, over: held), count: 1);
      await play(_playing(_t('a'), <Track>[_t('b')]));

      // 'c' needs 'b' gone; the queue moves on to 'd' while 'b' is deleted.
      final Completer<void> deleting = held.holdNextDelete();
      await play(_playing(_t('a2'), <Track>[_t('c')]));
      await play(_playing(_t('a3'), <Track>[_t('d')]));
      deleting.complete();
      await _settle();

      // 'c' is never written; the space goes straight to 'd'.
      expect(held.written, <String>['jellyfin_b', 'jellyfin_d']);
      expect(await cachedIds(), <String>{'d'});
    });

    test('one big download does not make every song look too big', () async {
      // A long recording fills most of the cache; a normal song still fits.
      downloader.sizes['jellyfin:mix'] = 40;
      final CacheDownloadRepository repo = repository(maxBytes: 48);
      await repo.requestDownload(_t('mix'));
      service(repo, count: 1);

      await play(_playing(_t('a'), <Track>[_t('b')]));

      expect(await cachedIds(), <String>{'mix', 'b'});
    });

    test('a track too big for the room stops downloading once that is clear',
        () async {
      // The user's download leaves 8 bytes free. The next episode is 20; the
      // song after it is an ordinary 4.
      downloader.sizes['jellyfin:big'] = 40;
      downloader.sizes['jellyfin:episode'] = 20;
      final CacheDownloadRepository repo = repository(maxBytes: 48);
      await repo.requestDownload(_t('big'));
      downloader.fetched.clear();
      service(repo, count: 1);

      await play(_playing(_t('a'), <Track>[_t('episode')]));
      // Given up at the first chunk, not pulled in full and thrown away.
      expect(downloader.fetched, <String>['jellyfin:episode']);
      expect(downloader.finished, isNot(contains('jellyfin:episode')));

      // And it says nothing about the song, which fits.
      await play(_playing(_t('a2'), <Track>[_t('song')]));
      expect(await cachedIds(), <String>{'big', 'song'});
    });

    test('warming further ahead never evicts the next track', () async {
      // Room for two: the third upcoming track must not push out the first.
      service(repository(maxBytes: 8));

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));

      expect(await cachedIds(), <String>{'b', 'c'});
      // And no data was spent on 'd' only to throw it away.
      expect(downloader.fetched, <String>['jellyfin:b', 'jellyfin:c']);
    });

    test('never deletes a download the user made, pinned or not', () async {
      final CacheDownloadRepository repo = repository(maxBytes: 8);
      await repo.requestDownload(_t('mine1'));
      await repo.requestDownload(_t('mine2'));
      downloader.fetched.clear();
      service(repo);

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      connectivity.change(NetworkStatus.offline);
      await _settle();
      connectivity.change(NetworkStatus.wifi);
      await _settle();
      await play(_playing(_t('b'), <Track>[_t('c'), _t('d')]));

      expect(await cachedIds(), <String>{'mine1', 'mine2'});
      expect(await repo.statusFor('mine1'), DownloadStatus.downloaded);
      expect(await repo.statusFor('mine2'), DownloadStatus.downloaded);
      expect(downloader.fetched, isEmpty);
    });

    test('the playing file is never evicted underneath playback', () async {
      final CacheDownloadRepository repo = repository(maxBytes: 12);
      service(repo);
      await play(_playing(_t('a'), <Track>[_t('b'), _t('c'), _t('d')]));
      expect(await cachedIds(), <String>{'b', 'c', 'd'});

      // 'b' (pre-cached) is playing now; a new queue needs room.
      await play(_playing(_t('b'), <Track>[_t('x'), _t('y')]));

      final Set<String> cached = await cachedIds();
      expect(cached, contains('b'));
      expect(cached, contains('x'));
    });
  });

  group('stale work', () {
    test('an account switch mid-download writes nothing for the old one',
        () async {
      service(repository());
      final Completer<void> b = downloader.holdNext('jellyfin:b');

      await play(_playing(_t('a'), <Track>[_t('b')]));
      account = 'jellyfin:account-2';
      b.complete();
      await _settle();

      expect(await store.loadDownloads(), isEmpty);
      expect(files.bytesFor('jellyfin_b.mp3'), isNull);
    });

    test('after an account switch the rest of the old queue is not fetched',
        () async {
      service(repository());
      final Completer<void> b = downloader.holdNext('jellyfin:b');

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      account = 'jellyfin:account-2';
      b.complete();
      await _settle();

      // 'c' came from the old account's catalog: never asked of the new one.
      expect(downloader.fetched, <String>['jellyfin:b']);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('network recovery never warms an old queue with a new account',
        () async {
      connectivity.status = NetworkStatus.offline;
      service(repository());

      await play(_playing(_t('a'), <Track>[_t('b')]));
      account = 'jellyfin:account-2';
      connectivity.change(NetworkStatus.wifi);
      await _settle();

      expect(downloader.fetched, isEmpty);
    });

    test('a sign-out while the bytes are being saved publishes nothing',
        () async {
      final _HeldWrites held = _HeldWrites(files);
      service(CacheDownloadRepository(
        store: store,
        files: held,
        downloader: downloader,
        connectivity: connectivity,
        preferences: InMemoryDownloadPreferences(),
        currentlyPlayingTrack: () => playing,
      ));
      final Completer<void> saving = held.holdNextWrite();

      await play(_playing(_t('a'), <Track>[_t('b')]));
      account = null;
      saving.complete();
      await _settle();

      expect(await store.loadDownloads(), isEmpty);
      expect(files.bytesFor('jellyfin_b.mp3'), isNull);
    });

    test('a sign-out mid-download writes nothing', () async {
      service(repository());
      final Completer<void> b = downloader.holdNext('jellyfin:b');

      await play(_playing(_t('a'), <Track>[_t('b')]));
      account = null;
      b.complete();
      await _settle();

      expect(await store.loadDownloads(), isEmpty);
    });

    test('disposal mid-download writes nothing and starts nothing new',
        () async {
      final SmartPrecacheService precache = service(repository());
      final Completer<void> b = downloader.holdNext('jellyfin:b');

      await play(_playing(_t('a'), <Track>[_t('b'), _t('c')]));
      await precache.dispose();
      b.complete();
      await _settle();

      expect(await store.loadDownloads(), isEmpty);
      expect(downloader.fetched, <String>['jellyfin:b']);
    });
  });
}
