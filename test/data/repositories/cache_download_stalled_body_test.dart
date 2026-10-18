// A download whose server stops sending fails, and gives up its slot.
//
// Downloads fetch a few at a time (DownloadScheduler), and the rest wait for a
// slot. The body of each one arrives while the cache writes it to disk
// (#745), so a server that sends the headers and part of the file, then
// nothing, would hold that slot for good, and every download queued behind it
// would sit at "queued" with it. The real Jellyfin downloader gives each chunk
// five minutes (downloadResponseBody); past that the download fails, its
// half-written draft is thrown away, and the next one in line starts.
//
// Run under fake time (testWidgets), so the minutes pass at once.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/repositories/offline_file_store.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/download_scheduler.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_download_source.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_track_downloader.dart';
import 'package:linthra/data/repositories/cache_download_repository.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';

class _Wifi implements ConnectivityService {
  @override
  Stream<NetworkStatus> get statusStream => const Stream<NetworkStatus>.empty();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// A signed-in Jellyfin whose download URL names the track.
class _SignedIn implements JellyfinDownloadSource {
  @override
  Future<void> verifyReachable() async {}

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => Uri.parse(
        'https://music.example.com/Items/${track.id}/Download'
        '?api_key=SECRET-TOKEN',
      );
}

/// Keeps every draft it hands out, so a test can see that nothing was left
/// half-written.
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

/// Advances fake time by [by], then lets what that set off run to its end.
///
/// A timed-out body's error, and a finished body's end, reach the cache's
/// `await for` only once the body's cancel has finished, and that finishes in
/// a root zone microtask, which fake time never runs on its own. Each empty
/// [WidgetTester.runAsync] lets the ones queued so far run; nothing waits on
/// real time.
Future<void> _advance(WidgetTester tester,
    [Duration by = Duration.zero]) async {
  await tester.pump(by);
  for (int round = 0; round < 5; round++) {
    await tester.runAsync<void>(() async {});
    await tester.pump();
  }
}

void main() {
  testWidgets(
      'a stalled download fails, leaves no draft, and the next one in line '
      'downloads', (tester) async {
    final Map<String, StreamController<List<int>>> bodies =
        <String, StreamController<List<int>>>{
      'a': StreamController<List<int>>(),
      'b': StreamController<List<int>>(),
    };
    final List<String> served = <String>[];
    final MockClient server = MockClient.streaming(
      (http.BaseRequest request, http.ByteStream _) async {
        final String id = request.url.pathSegments[1];
        served.add(id);
        return http.StreamedResponse(
          bodies[id]!.stream,
          200,
          contentLength: 8,
          headers: const <String, String>{'content-type': 'audio/mpeg'},
        );
      },
    );
    final InMemoryDownloadStore store = InMemoryDownloadStore();
    final _DraftsFileStore files = _DraftsFileStore(InMemoryOfflineFileStore());
    final CacheDownloadRepository repository = CacheDownloadRepository(
      store: store,
      files: files,
      downloader:
          JellyfinTrackDownloader(() => _SignedIn(), httpClient: server),
      connectivity: _Wifi(),
      preferences: InMemoryDownloadPreferences(),
      scheduler: DownloadScheduler(maxConcurrent: 1),
    );

    DownloadRequestOutcome? aOutcome;
    DownloadRequestOutcome? bOutcome;
    unawaited(repository
        .requestDownload(_jellyfin('a'))
        .then((DownloadRequestOutcome o) => aOutcome = o));
    unawaited(repository
        .requestDownload(_jellyfin('b'))
        .then((DownloadRequestOutcome o) => bOutcome = o));
    await _advance(tester);

    // Half of a arrives, then the server goes quiet.
    bodies['a']!.add(const <int>[1, 2, 3, 4]);
    await _advance(tester);
    expect(served, <String>['a']);
    expect(files.drafts.single.length, 4);

    // Four minutes on it is a slow server, not yet a dead one: a still holds
    // the one slot and b still waits for it.
    await _advance(tester, const Duration(minutes: 4));
    expect(await repository.statusFor('a'), DownloadStatus.downloading);
    expect(await repository.statusFor('b'), DownloadStatus.queued);
    expect(served, <String>['a']);

    await _advance(tester, const Duration(minutes: 1, seconds: 1));

    // a gave up: failed (its row offers a retry), nothing kept of it.
    expect(aOutcome, DownloadRequestOutcome.started);
    expect(await repository.statusFor('a'), DownloadStatus.failed);
    expect(files.drafts.first.discarded, isTrue);
    expect(files.bytesFor('jellyfin_a.mp3'), isNull);
    // Its slot went to b, which is fetching now.
    expect(served, <String>['a', 'b']);
    expect(await repository.statusFor('b'), DownloadStatus.downloading);

    bodies['b']!
      ..add(const <int>[5, 6, 7, 8])
      ..add(const <int>[9, 10, 11, 12]);
    unawaited(bodies['b']!.close());
    await _advance(tester);

    expect(bOutcome, DownloadRequestOutcome.started);
    expect(await repository.statusFor('b'), DownloadStatus.downloaded);
    expect(files.bytesFor('jellyfin_b.mp3'), <int>[5, 6, 7, 8, 9, 10, 11, 12]);
    expect(
      (await store.loadDownloads()).map((CachedTrack c) => c.trackId),
      <String>['b'],
    );

    await repository.dispose();
  });
}
