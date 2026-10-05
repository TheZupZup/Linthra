import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

/// Downloads are written to disk as they arrive, and stop as soon as it is
/// clear they won't be kept (#745).

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// One download's body, fed by the test a chunk at a time.
class _Body {
  _Body({this.length}) {
    _controller = StreamController<List<int>>(
      // A subscription is also cancelled once the body has ended, which is no
      // stop.
      onCancel: () => cancelled = !_ended,
    );
  }

  final int? length;
  late final StreamController<List<int>> _controller;
  bool _ended = false;

  /// Whoever read the body stopped before it ended.
  bool cancelled = false;

  Stream<List<int>> get stream => _controller.stream;

  void add(List<int> chunk) => _controller.add(chunk);

  void fail(Object error) => _controller.addError(error);

  Future<void> end() {
    _ended = true;
    return _controller.close();
  }
}

/// Hands back each fetch's body while it is still arriving, the way the real
/// downloaders do, from the bodies the test queued.
class _StreamingDownloader implements RemoteTrackDownloader {
  final List<_Body> bodies = <_Body>[];
  int fetchCount = 0;

  _Body next({int? length}) {
    final _Body body = _Body(length: length);
    bodies.add(body);
    return body;
  }

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final _Body body = bodies[fetchCount++];
    return RemoteTrackData.streamed(
      body: body.stream,
      length: body.length,
      fileExtension: 'mp3',
    );
  }
}

/// A downloader of the kind #745 describes: it reports progress as each chunk
/// arrives, with the size the server announced, and keeps reading until it is
/// stopped.
class _ReportingDownloader implements RemoteTrackDownloader {
  _ReportingDownloader({required this.announced});

  final int announced;
  int delivered = 0;

  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final List<int> received = <int>[];
    for (int chunk = 0; chunk < 100; chunk++) {
      await Future<void>.delayed(Duration.zero);
      received.addAll(const <int>[1, 2, 3, 4]);
      delivered++;
      onProgress?.call(received.length, announced);
    }
    return RemoteTrackData(bytes: received, fileExtension: 'mp3');
  }
}

/// Keeps every draft it hands out, so a test can see what reached the disk
/// while a download is still arriving, and that nothing is left behind.
class _DraftsFileStore implements OfflineFileStore {
  _DraftsFileStore(this._inner);

  final InMemoryOfflineFileStore _inner;
  final List<_TrackedDraft> drafts = <_TrackedDraft>[];

  List<int>? bytesFor(String fileName) => _inner.bytesFor(fileName);

  @override
  Future<OfflineFileDraft> createDraft(String trackId) async {
    final _TrackedDraft draft =
        _TrackedDraft(await _inner.createDraft(trackId));
    drafts.add(draft);
    return draft;
  }

  @override
  Future<String?> pathFor(String fileName) => _inner.pathFor(fileName);

  @override
  Future<int?> sizeFor(String fileName) => _inner.sizeFor(fileName);

  @override
  Future<void> delete(String fileName) => _inner.delete(fileName);

  @override
  Future<void> removeAbandoned(
    Set<String> referenced, {
    bool temporaryOnly = false,
  }) =>
      _inner.removeAbandoned(referenced, temporaryOnly: temporaryOnly);
}

class _TrackedDraft implements OfflineFileDraft {
  _TrackedDraft(this._inner);

  final OfflineFileDraft _inner;
  bool published = false;
  bool discarded = false;

  /// Neither published nor discarded: a temp file still on disk.
  bool get open => !published && !discarded;

  @override
  int get length => _inner.length;

  @override
  Future<void> add(List<int> chunk) => _inner.add(chunk);

  @override
  Future<String> publish({String? extension}) async {
    final String name = await _inner.publish(extension: extension);
    published = true;
    return name;
  }

  @override
  Future<void> discard() async {
    if (!published) discarded = true;
    await _inner.discard();
  }
}

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

/// Lets pending async work run.
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late InMemoryDownloadStore store;
  late _DraftsFileStore files;
  late InMemoryDownloadPreferences preferences;

  setUp(() {
    store = InMemoryDownloadStore();
    files = _DraftsFileStore(InMemoryOfflineFileStore());
    preferences = InMemoryDownloadPreferences(maxCacheBytes: 10);
  });

  CacheDownloadRepository build(RemoteTrackDownloader downloader) {
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader: downloader,
      connectivity: _Wifi(),
      preferences: preferences,
    );
    addTearDown(repository.dispose);
    return repository;
  }

  group('a download bigger than the cache limit', () {
    test('stops after the first chunk once its announced size is over',
        () async {
      // The cache limit is 10 bytes and the server says 11.
      final _ReportingDownloader downloader =
          _ReportingDownloader(announced: 11);
      final CacheDownloadRepository repository = build(downloader);

      await expectLater(
        repository.requestDownload(_jellyfin('j1')),
        throwsA(isA<CacheStorageException>()),
      );

      expect(downloader.delivered, 1);
      expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('is refused on its announced size before any of the body is read',
        () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 11);
      final CacheDownloadRepository repository = build(downloader);

      await expectLater(
        repository.requestDownload(_jellyfin('j1')),
        throwsA(isA<CacheStorageException>()),
      );

      expect(body.cancelled, isTrue);
      expect(files.drafts, isEmpty);
      expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('with no announced size, stops at the chunk that passes the limit',
        () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next();
      final CacheDownloadRepository repository = build(downloader);

      final Future<DownloadRequestOutcome> request =
          repository.requestDownload(_jellyfin('j1'));
      await _settle();
      body.add(const <int>[1, 2, 3, 4, 5, 6]);
      await _settle();
      expect(body.cancelled, isFalse);
      body.add(const <int>[7, 8, 9, 10, 11]);

      await expectLater(request, throwsA(isA<CacheStorageException>()));
      expect(body.cancelled, isTrue);
      expect(files.drafts.single.discarded, isTrue);
      expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      expect(await store.loadDownloads(), isEmpty);
    });

    test(
        'an announced size that fits, then more bytes than that, still stops '
        'at the chunk that passes the limit', () async {
      // The server says 6 bytes, and keeps sending past them.
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 6);
      final CacheDownloadRepository repository = build(downloader);

      final Future<void> refused = expectLater(
        repository.requestDownload(_jellyfin('j1')),
        throwsA(isA<CacheStorageException>()),
      );
      await _settle();
      body.add(const <int>[1, 2, 3, 4, 5, 6]);
      await _settle();
      expect(body.cancelled, isFalse);
      body.add(const <int>[7, 8, 9, 10, 11]);
      await _settle();
      // Read to the end, the body would only be refused at the commit.
      unawaited(body.end());

      await refused;
      expect(body.cancelled, isTrue);
      expect(files.drafts.single.discarded, isTrue);
      expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
    });

    test('a pre-cache over its room is refused before its body is read',
        () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 11);
      final CacheDownloadRepository repository = build(downloader);

      await repository.prefetch(_jellyfin('j1'));

      expect(body.cancelled, isTrue);
      expect(files.drafts, isEmpty);
      expect(await store.loadDownloads(), isEmpty);
    });
  });

  group('the body goes to disk as it arrives', () {
    test('each chunk is in the draft before the next one arrives', () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 8);
      final CacheDownloadRepository repository = build(downloader);

      final Future<DownloadRequestOutcome> request =
          repository.requestDownload(_jellyfin('j1'));
      await _settle();
      body.add(const <int>[1, 2, 3, 4]);
      await _settle();

      expect(files.drafts.single.length, 4);
      expect(await repository.statusFor('j1'), DownloadStatus.downloading);
      expect(await store.loadDownloads(), isEmpty);

      body.add(const <int>[5, 6, 7, 8]);
      await _settle();
      expect(files.drafts.single.length, 8);
      await body.end();
      await request;

      expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      final CachedTrack saved = (await store.loadDownloads()).single;
      expect(saved.sizeBytes, 8);
      expect(files.bytesFor(saved.fileName!), <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      expect(files.drafts.single.published, isTrue);
    });

    test('a body that fails part way leaves no draft and reads failed',
        () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 8);
      final CacheDownloadRepository repository = build(downloader);

      final Future<DownloadRequestOutcome> request =
          repository.requestDownload(_jellyfin('j1'));
      await _settle();
      body.add(const <int>[1, 2, 3, 4]);
      await _settle();
      body.fail(StateError('Download failed.'));
      await request;

      expect(await repository.statusFor('j1'), DownloadStatus.failed);
      expect(files.drafts.single.discarded, isTrue);
      expect(await store.loadDownloads(), isEmpty);
    });
  });

  group('a download that is no longer wanted stops arriving', () {
    test('removing it mid-transfer stops the transfer', () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 8);
      final CacheDownloadRepository repository = build(downloader);

      final Future<DownloadRequestOutcome> request =
          repository.requestDownload(_jellyfin('j1'));
      await _settle();
      body.add(const <int>[1, 2, 3, 4]);
      await _settle();

      await repository.removeDownload(_jellyfin('j1'));
      body.add(const <int>[5, 6, 7, 8]);
      await request;

      expect(body.cancelled, isTrue);
      expect(files.drafts.single.discarded, isTrue);
      expect(await repository.statusFor('j1'), DownloadStatus.notDownloaded);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('asked for again before the next chunk, the same transfer goes on',
        () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 8);
      final CacheDownloadRepository repository = build(downloader);

      final Future<DownloadRequestOutcome> request =
          repository.requestDownload(_jellyfin('j1'));
      await _settle();
      body.add(const <int>[1, 2, 3, 4]);
      await _settle();
      await repository.removeDownload(_jellyfin('j1'));
      await repository.requestDownload(_jellyfin('j1'));

      body.add(const <int>[5, 6, 7, 8]);
      await body.end();
      await request;

      expect(downloader.fetchCount, 1);
      expect(body.cancelled, isFalse);
      expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      expect((await store.loadDownloads()).single.sizeBytes, 8);
    });

    test('asked for again after it stopped, it is fetched afresh', () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body first = downloader.next(length: 8);
      final _Body second = downloader.next(length: 8);
      final CacheDownloadRepository repository = build(downloader);

      final Future<DownloadRequestOutcome> stopped =
          repository.requestDownload(_jellyfin('j1'));
      await _settle();
      first.add(const <int>[1, 2, 3, 4]);
      await _settle();
      await repository.removeDownload(_jellyfin('j1'));
      first.add(const <int>[5, 6, 7, 8]);
      await stopped;
      expect(first.cancelled, isTrue);

      final Future<DownloadRequestOutcome> again =
          repository.requestDownload(_jellyfin('j1'));
      await _settle();
      second.add(const <int>[8, 7, 6, 5, 4, 3, 2, 1]);
      await second.end();
      await again;

      expect(downloader.fetchCount, 2);
      expect(await repository.statusFor('j1'), DownloadStatus.downloaded);
      final CachedTrack saved = (await store.loadDownloads()).single;
      expect(files.bytesFor(saved.fileName!), <int>[8, 7, 6, 5, 4, 3, 2, 1]);
      expect(files.drafts.where((_TrackedDraft d) => d.open), isEmpty);
    });

    test('a pre-cache stops once the session that asked for it is gone',
        () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 8);
      final CacheDownloadRepository repository = build(downloader);
      bool signedIn = true;

      final Future<void> precache = repository.prefetch(
        _jellyfin('j1'),
        isStillWanted: () => signedIn,
      );
      await _settle();
      body.add(const <int>[1, 2, 3, 4]);
      await _settle();
      signedIn = false;
      body.add(const <int>[5, 6, 7, 8]);
      await precache;

      expect(body.cancelled, isTrue);
      expect(files.drafts.single.discarded, isTrue);
      expect(await store.loadDownloads(), isEmpty);
    });

    test('a pre-cache whose queue only moved on still keeps a copy that fits',
        () async {
      final _StreamingDownloader downloader = _StreamingDownloader();
      final _Body body = downloader.next(length: 8);
      final CacheDownloadRepository repository = build(downloader);
      bool queueStillThere = true;

      final Future<void> precache = repository.prefetch(
        _jellyfin('j1'),
        mayMakeRoom: () => queueStillThere,
      );
      await _settle();
      body.add(const <int>[1, 2, 3, 4]);
      await _settle();
      queueStillThere = false;
      body.add(const <int>[5, 6, 7, 8]);
      await body.end();
      await precache;

      expect(body.cancelled, isFalse);
      final CachedTrack saved = (await store.loadDownloads()).single;
      expect(saved.preloaded, isTrue);
      expect(saved.sizeBytes, 8);
    });
  });
}
