// A walk that could not read part of a selected folder, wired the way the app
// wires it: the Settings rescan (the folder watcher makes the same call), the
// scan, the real Drift catalog that stores the stamps, and the artwork sweep
// that follows every write.
//
// Such a walk may add and update tracks, but it must never conclude that a
// track indexed under the part it could not read is gone. On desktop that part
// is a subfolder that stopped answering (its permissions changed, or a network
// mount inside the music folder went stale); on Android it is a subtree of the
// SAF folder the content resolver could not list. The merge rules themselves
// are covered in test/core/sources/local/local_library_scanner_test.dart.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/stamped_catalog_writer.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/local_scan_report_provider.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import '../../core/sources/local/fake_saf_document_lister.dart';
import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

/// Tags keyed by path, and an artwork cache that is recorded rather than
/// written: the desktop reader, as a scan sees it.
class _TagReader implements LocalMetadataReader, LocalArtworkMaintainer {
  _TagReader(this.byPath);

  Map<String, LocalAudioMetadata> byPath;

  /// Every path whose tags were parsed, in order.
  final List<String> reads = <String>[];

  /// The covers each sweep was told to keep, one entry per sweep.
  final List<Set<Uri>> sweeps = <Set<Uri>>[];

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async {
    reads.add(path);
    return byPath[path];
  }

  @override
  Future<void> retainArtwork(Set<Uri> live) async => sweeps.add(live);
}

class _FakeStatReader implements LocalFileStatReader {
  _FakeStatReader(this.stamps);

  Map<String, LocalFileStamp> stamps;

  @override
  Future<LocalFileStamp?> stamp(String path) async => stamps[path];
}

/// A catalog that can list what it holds but cannot read one source's slice
/// back, so a scan has nothing to carry an unread part's tracks over from.
class _SliceBlindRepository implements MusicLibraryRepository {
  _SliceBlindRepository(this._delegate);

  final InMemoryMusicLibraryRepository _delegate;

  /// How many times a scan replaced the catalog.
  int writes = 0;

  @override
  Future<List<Track>> getAllTracks() => _delegate.getAllTracks();

  @override
  Future<List<Album>> getAllAlbums() => _delegate.getAllAlbums();

  @override
  Future<List<Artist>> getAllArtists() => _delegate.getAllArtists();

  @override
  Future<Track?> getTrackByUri(String uri) => _delegate.getTrackByUri(uri);

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) {
    writes++;
    return _delegate.upsertCatalog(
      sourceId: sourceId,
      tracks: tracks,
      albums: albums,
      artists: artists,
    );
  }

  @override
  Future<void> removeTracks(List<String> trackUris) =>
      _delegate.removeTracks(trackUris);
}

Uri _cover(String title) => Uri.file('/cache/local_artwork/$title.img');

LocalAudioMetadata _tags(String title) => LocalAudioMetadata(
      title: title,
      artist: 'Someone',
      album: 'Something',
      duration: const Duration(minutes: 3),
      artworkUri: _cover(title),
    );

LocalFileStamp _stamp(int size, int mtime) =>
    LocalFileStamp(sizeBytes: size, modifiedAtMs: mtime);

const String _one = '/music/A/one.flac';
const String _two = '/music/A/two.flac';
const String _three = '/music/B/three.flac';
const String _four = '/music/B/four.flac';

List<String> _sortedUris(List<Track> tracks) =>
    tracks.map((Track t) => t.uri).toList()..sort();

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  group('on desktop', () {
    late FakeAudioFileScanner files;
    late _TagReader tags;
    late _FakeStatReader stats;

    /// The real Drift catalog over in-memory SQLite, so the stamps make an
    /// actual round trip, unless [repository] stands in for it.
    ProviderContainer container({MusicLibraryRepository? repository}) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          folderPickerServiceProvider
              .overrideWithValue(FakeFolderPickerService()),
          selectedMusicFolderRepositoryProvider.overrideWithValue(
            InMemorySelectedMusicFolderRepository(
              initialFolders: const <String>['/music'],
            ),
          ),
          if (repository != null)
            musicLibraryRepositoryProvider.overrideWithValue(repository)
          else ...<Override>[
            linthraDatabaseExecutorProvider.overrideWithValue(
              NativeDatabase.memory(),
            ),
            driftMusicLibraryRepositoryOverride,
          ],
          audioFileScannerProvider.overrideWithValue(files),
          localMetadataReaderProvider.overrideWithValue(tags),
          localFileStatReaderProvider.overrideWithValue(stats),
          hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      files = FakeAudioFileScanner(filesByFolder: <String, List<String>>{
        '/music': <String>[_one, _two, _three, _four],
      });
      tags = _TagReader(<String, LocalAudioMetadata>{
        _one: _tags('One'),
        _two: _tags('Two'),
        _three: _tags('Three'),
        _four: _tags('Four'),
      });
      stats = _FakeStatReader(<String, LocalFileStamp>{
        _one: _stamp(100, 1000),
        _two: _stamp(200, 2000),
        _three: _stamp(300, 3000),
        _four: _stamp(400, 4000),
      });
    });

    Future<void> rescan(ProviderContainer c) =>
        c.read(localMusicControllerProvider.notifier).rescan();

    Future<List<Track>> catalog(ProviderContainer c) =>
        c.read(musicLibraryRepositoryProvider).getAllTracks();

    Future<Map<String, LocalFileStamp?>> storedStamps(
      ProviderContainer c,
    ) async {
      final List<StampedTrack> rows =
          await (c.read(musicLibraryRepositoryProvider) as StampedCatalogWriter)
              .getStampedTracksForSource('local');
      return <String, LocalFileStamp?>{
        for (final StampedTrack row in rows) row.track.uri: row.stamp,
      };
    }

    /// B stops answering: its files are still on disk, but the walk cannot
    /// list it any more, so it reports the folder instead of returning them.
    void loseB({List<String> inA = const <String>[_one, _two]}) {
      files.filesByFolder = <String, List<String>>{'/music': inA};
      files.unreadableByFolder = <String, List<String>>{
        '/music': <String>['/music/B'],
      };
    }

    /// B answers again, holding [inB].
    void restoreB({List<String> inB = const <String>[_three, _four]}) {
      files.filesByFolder = <String, List<String>>{
        '/music': <String>[_one, _two, ...inB],
      };
      files.unreadableByFolder = const <String, List<String>>{};
    }

    group('a subfolder the walk could not read', () {
      test('keeps the tracks indexed under it, with the stamps they had',
          () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);
        final Map<String, LocalFileStamp?> before = await storedStamps(c);

        loseB();
        await rescan(c);

        expect(
          _sortedUris(await catalog(c)),
          <String>[_one, _two, _four, _three],
          reason: 'B could not be read, so nothing under it is known to be '
              'gone',
        );
        final Map<String, LocalFileStamp?> after = await storedStamps(c);
        expect(before[_three], _stamp(300, 3000));
        expect(after[_three], before[_three]);
        expect(after[_four], before[_four]);
        expect(
          (await catalog(c)).singleWhere((Track t) => t.uri == _three).title,
          'Three',
        );
      });

      test('still applies what the walk learned about the part it did read',
          () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);

        // In A, one.flac is re-tagged, two.flac is deleted and five.flac is
        // new, all while B is unreadable.
        const String five = '/music/A/five.flac';
        stats.stamps[_one] = _stamp(101, 1001);
        stats.stamps[five] = _stamp(500, 5000);
        tags.byPath[_one] = _tags('One (remastered)');
        tags.byPath[five] = _tags('Five');
        loseB(inA: <String>[_one, five]);
        tags.reads.clear();
        await rescan(c);

        expect(
          _sortedUris(await catalog(c)),
          <String>[five, _one, _four, _three],
        );
        expect(
          (await catalog(c)).singleWhere((Track t) => t.uri == _one).title,
          'One (remastered)',
        );
        expect(tags.reads, unorderedEquals(<String>[_one, five]));
      });

      test('keeps their covers through the sweep that follows the write',
          () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);

        loseB();
        await rescan(c);

        expect(tags.sweeps, hasLength(2));
        expect(tags.sweeps.last, <Uri>{
          _cover('One'),
          _cover('Two'),
          _cover('Three'),
          _cover('Four'),
        });
      });

      test('is counted as unreadable, for the Settings card and diagnostics',
          () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);

        loseB();
        await rescan(c);

        expect(c.read(localScanReportProvider)?.readFailures, 1);
        expect(c.read(localScanReportProvider)?.hadError, isFalse);
      });

      test('is not parsed again once it answers', () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);
        loseB();
        await rescan(c);

        restoreB();
        tags.reads.clear();
        await rescan(c);

        expect(
          tags.reads,
          isEmpty,
          reason: 'B kept the stamps it was indexed with, so reading it again '
              'finds nothing changed',
        );
      });
    });

    group('controls', () {
      test('once the subfolder answers, a file deleted from it goes', () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);
        loseB();
        await rescan(c);

        // four.flac was deleted while B could not be read.
        restoreB(inB: <String>[_three]);
        await rescan(c);

        expect(_sortedUris(await catalog(c)), <String>[_one, _two, _three]);
      });

      test('a complete rescan still removes a deleted file', () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);

        files.filesByFolder = <String, List<String>>{
          '/music': <String>[_one, _three, _four],
        };
        await rescan(c);

        expect(_sortedUris(await catalog(c)), <String>[_one, _four, _three]);
        expect(c.read(localScanReportProvider)?.readFailures, 0);
      });

      test('a selected folder that cannot be read at all writes nothing',
          () async {
        final ProviderContainer c = container();
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);

        files.unavailable = <String>{'/music'};
        await rescan(c);

        expect(
          _sortedUris(await catalog(c)),
          <String>[_one, _two, _four, _three],
        );
        expect(c.read(localScanReportProvider)?.hadError, isTrue);
      });
    });

    group('when the indexed tracks cannot be read back', () {
      test('a walk that missed a subfolder writes nothing', () async {
        final InMemoryMusicLibraryRepository stored =
            InMemoryMusicLibraryRepository();
        final _SliceBlindRepository repository = _SliceBlindRepository(stored);
        final ProviderContainer c = container(repository: repository);
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);
        expect(repository.writes, 1);

        loseB();
        await rescan(c);

        expect(
          repository.writes,
          1,
          reason: "with no way to keep B's tracks, writing the walk would "
              'delete them',
        );
        expect(
          _sortedUris(await stored.getAllTracks()),
          <String>[_one, _two, _four, _three],
        );
      });

      test('a walk that read everything is still written', () async {
        final InMemoryMusicLibraryRepository stored =
            InMemoryMusicLibraryRepository();
        final _SliceBlindRepository repository = _SliceBlindRepository(stored);
        final ProviderContainer c = container(repository: repository);
        await c.read(selectedFolderControllerProvider.future);
        await rescan(c);

        files.filesByFolder = <String, List<String>>{
          '/music': <String>[_one, _three, _four],
        };
        await rescan(c);

        expect(repository.writes, 2);
        expect(
          _sortedUris(await stored.getAllTracks()),
          <String>[_one, _four, _three],
        );
      });
    });
  });

  group('on Android, a SAF folder', () {
    const String tree =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';

    /// A document under [tree], with the uri the native walk builds for it.
    SafAudioDocument document(String folder, String name) => SafAudioDocument(
          uri: '$tree/document/primary%3AMusic%2F$folder%2F$name',
          name: name,
        );

    final SafAudioDocument inA = document('A', 'a.mp3');
    final SafAudioDocument inB = document('B', 'b.mp3');
    final SafAudioDocument inC = document('C', 'c.mp3');

    late FakeSafDocumentLister saf;
    late InMemoryMusicLibraryRepository stored;

    ProviderContainer container() {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          musicLibraryRepositoryProvider.overrideWithValue(stored),
          safDocumentListerProvider.overrideWithValue(saf),
          // The content resolver walk is the one that must answer.
          audioFileScannerProvider.overrideWithValue(
            FakeAudioFileScanner(error: Exception('should not walk files')),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      saf = FakeSafDocumentLister(
        documents: <SafAudioDocument>[inA, inB, inC],
      );
      stored = InMemoryMusicLibraryRepository();
    });

    Future<void> scan(ProviderContainer c) =>
        c.read(libraryControllerProvider.notifier).scanFolders(<String>[tree]);

    Future<List<String>> catalogUris() async =>
        _sortedUris(await stored.getAllTracks());

    test('keeps everything when the walk cannot say which part it missed',
        () async {
      final ProviderContainer c = container();
      await scan(c);
      expect(await catalogUris(), <String>[inA.uri, inB.uri, inC.uri]);

      // B and C stopped answering mid-walk (an SD card pulled, a provider
      // hiccup): the walk returns only A, and counts two subfolders it could
      // not list without saying which.
      saf.documents = <SafAudioDocument>[inA];
      saf.readFailures = 2;
      await scan(c);

      expect(await catalogUris(), <String>[inA.uri, inB.uri, inC.uri]);
      expect(c.read(localScanReportProvider)?.readFailures, 2);
    });

    test('a walk that reads the whole tree again removes what is gone',
        () async {
      final ProviderContainer c = container();
      await scan(c);
      saf.documents = <SafAudioDocument>[inA];
      saf.readFailures = 2;
      await scan(c);
      expect(await catalogUris(), <String>[inA.uri, inB.uri, inC.uri]);

      // Everything answers again, and C turns out to have been deleted.
      saf.documents = <SafAudioDocument>[inA, inB];
      saf.readFailures = 0;
      await scan(c);

      expect(await catalogUris(), <String>[inA.uri, inB.uri]);
    });
  });
}
