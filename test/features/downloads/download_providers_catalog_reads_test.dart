import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/downloads/download_providers.dart';

import '../library/fake_music_library_repository.dart';

/// A download repository that only publishes status maps, pushed by the test.
class _StatusSource implements DownloadRepository {
  final StreamController<Map<String, DownloadStatus>> _changes =
      StreamController<Map<String, DownloadStatus>>.broadcast();
  Map<String, DownloadStatus> _statuses = const <String, DownloadStatus>{};

  void set(String key, DownloadStatus status) =>
      push(<String, DownloadStatus>{..._statuses, key: status});

  void remove(String key) =>
      push(<String, DownloadStatus>{..._statuses}..remove(key));

  void push(Map<String, DownloadStatus> statuses) {
    _statuses = Map<String, DownloadStatus>.unmodifiable(statuses);
    _changes.add(_statuses);
  }

  @override
  Stream<Map<String, DownloadStatus>> get statusStream async* {
    yield _statuses;
    yield* _changes.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

/// A catalog that counts its full reads, and can hold them open.
class _CountingCatalog extends FakeMusicLibraryRepository {
  _CountingCatalog({required super.tracks});

  int reads = 0;
  Completer<void>? hold;

  @override
  Future<List<Track>> getAllTracks() async {
    reads++;
    final Completer<void>? gate = hold;
    if (gate != null) await gate.future;
    return super.getAllTracks();
  }
}

Track _track(String id) =>
    Track(id: id, title: 'Song $id', uri: 'jellyfin:$id');

String _key(Track track) => CachedTrack.cacheKeyForTrack(track);

Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final List<Track> library = <Track>[
    for (int i = 0; i < 50; i++) _track('$i'),
  ];

  late _StatusSource statuses;
  late _CountingCatalog catalog;
  late ProviderContainer container;

  setUp(() {
    statuses = _StatusSource();
    catalog = _CountingCatalog(tracks: library);
    container = ProviderContainer(
      overrides: <Override>[
        downloadRepositoryProvider.overrideWithValue(statuses),
        musicLibraryRepositoryProvider.overrideWithValue(catalog),
      ],
    );
    addTearDown(container.dispose);
    // The Downloads screen watches both lists.
    container.listen(downloadedTracksProvider, (_, __) {});
    container.listen(activeDownloadsProvider, (_, __) {});
  });

  // #746: both lists read the whole catalog for every status change, and
  // "Download all" on a big playlist is well over a thousand of them.
  group('the Downloads lists read the catalog only for new keys (#746)', () {
    test('one track walking through ~30 status changes costs one read',
        () async {
      await _settle();
      final int start = catalog.reads;
      final String key = _key(library[3]);

      statuses.set(key, DownloadStatus.queued);
      for (int i = 0; i < 14; i++) {
        statuses.set(key, DownloadStatus.downloading);
        await _settle();
        statuses.set(key, DownloadStatus.queued);
      }
      statuses.set(key, DownloadStatus.downloading);
      statuses.set(key, DownloadStatus.downloaded);
      await _settle();

      expect(catalog.reads - start, 1);
      expect(container.read(downloadedTracksProvider).value, <Track>[
        library[3],
      ]);
      expect(container.read(activeDownloadsProvider).value, isEmpty);
    });

    test('a batch queued together costs one read for all of it', () async {
      await _settle();
      final int start = catalog.reads;

      statuses.push(<String, DownloadStatus>{
        for (final Track track in library.take(20))
          _key(track): DownloadStatus.queued,
      });
      await _settle();
      // Every one of them runs and finishes, one event at a time.
      for (final Track track in library.take(20)) {
        statuses.set(_key(track), DownloadStatus.downloading);
        statuses.set(_key(track), DownloadStatus.downloaded);
      }
      await _settle();

      expect(catalog.reads - start, 1);
      expect(container.read(downloadedTracksProvider).value, hasLength(20));
    });

    test('a burst that lands while a read is out is joined once', () async {
      await _settle();
      final int start = catalog.reads;
      catalog.hold = Completer<void>();

      for (final Track track in library.take(10)) {
        statuses.set(_key(track), DownloadStatus.queued);
        await _settle();
      }
      catalog.hold!.complete();
      catalog.hold = null;
      await _settle();

      expect(catalog.reads - start, lessThanOrEqualTo(2));
      expect(
        container.read(activeDownloadsProvider).value!.map((d) => d.track),
        unorderedEquals(library.take(10)),
      );
    });

    test('a status change that moves nothing keeps the finished list as is',
        () async {
      statuses.set(_key(library[0]), DownloadStatus.downloaded);
      statuses.set(_key(library[1]), DownloadStatus.queued);
      await _settle();
      final List<Track> before =
          container.read(downloadedTracksProvider).value!;

      statuses.set(_key(library[1]), DownloadStatus.downloading);
      await _settle();

      expect(identical(container.read(downloadedTracksProvider).value, before),
          isTrue);
      expect(container.read(activeDownloadsProvider).value!.single.status,
          DownloadStatus.downloading);
    });

    test('lists still follow removals and keep catalog and status order',
        () async {
      statuses.push(<String, DownloadStatus>{
        _key(library[5]): DownloadStatus.downloaded,
        _key(library[2]): DownloadStatus.downloaded,
        _key(library[9]): DownloadStatus.failed,
        _key(library[7]): DownloadStatus.queued,
        _key(library[8]): DownloadStatus.downloading,
      });
      await _settle();
      final int reads = catalog.reads;

      expect(container.read(downloadedTracksProvider).value,
          <Track>[library[2], library[5]]);
      expect(
        container.read(activeDownloadsProvider).value!.map((d) => d.track),
        <Track>[library[8], library[7], library[9]],
      );

      statuses.remove(_key(library[2]));
      statuses.remove(_key(library[9]));
      await _settle();

      expect(catalog.reads, reads, reason: 'nothing new to look up');
      expect(
          container.read(downloadedTracksProvider).value, <Track>[library[5]]);
      expect(
        container.read(activeDownloadsProvider).value!.map((d) => d.track),
        <Track>[library[8], library[7]],
      );
    });

    test('a catalog that cannot be read is reported as an error', () async {
      final ProviderContainer failing = ProviderContainer(
        overrides: <Override>[
          downloadRepositoryProvider.overrideWithValue(statuses),
          musicLibraryRepositoryProvider.overrideWithValue(
            FakeMusicLibraryRepository(error: Exception('db locked')),
          ),
        ],
      );
      addTearDown(failing.dispose);
      failing.listen(downloadedTracksProvider, (_, __) {});
      await _settle();

      expect(failing.read(downloadedTracksProvider).hasError, isTrue);
    });
  });
}
