// The incremental scan wired the way the app wires it (#411): the Settings
// rescan action, the scan, and the real Drift catalog storing the stamps.
//
// The single-source rules live in
// test/core/sources/local/local_incremental_scan_test.dart. This is about the
// round trip: stamps written by one scan are what the next scan reads back.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_file_stat.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_local_tag_revision_store.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/local_tag_revision_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/local_scan_report_provider.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_folder_picker_service.dart';

/// A filesystem whose contents *and* availability can change between scans,
/// which is what an incremental test is about: the shared FakeAudioFileScanner
/// is fixed at construction, and this needs a drive to be unplugged and
/// plugged back in while the same container keeps running.
class _MutableScanner implements AudioFileScanner {
  _MutableScanner(this.filesByFolder);

  Map<String, List<String>> filesByFolder;
  Set<String> unavailable = <String>{};

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
  }) async {
    if (unavailable.contains(folder)) {
      throw FolderScanException(
        "Linthra couldn't find the selected folder.",
        folder: folder,
      );
    }
    return filesByFolder[folder] ?? const <String>[];
  }
}

class _CountingMetadataReader implements LocalMetadataReader {
  final List<String> reads = <String>[];

  int get readCount => reads.length;

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async {
    reads.add(path);
    return const LocalAudioMetadata(
      title: 'Tagged',
      artist: 'Someone',
      album: 'Something',
      duration: Duration(minutes: 3),
    );
  }
}

/// A tag reader that says which revision of tag reading it is, the way the
/// filesystem reader does; [tagRevision] goes up when Linthra is updated with
/// a change to how tags are read.
class _RevisedMetadataReader extends _CountingMetadataReader
    implements LocalTagRevision {
  @override
  int tagRevision = 1;

  /// Files whose read comes back with nothing: a share that answered with an
  /// I/O error, a parse that ran out of time.
  Set<String> failing = <String>{};

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async {
    final LocalAudioMetadata? metadata = await super.readFromPath(path);
    return failing.contains(path) ? null : metadata;
  }
}

class _FakeStatReader implements LocalFileStatReader {
  _FakeStatReader(this.stamps);

  Map<String, LocalFileStamp> stamps;

  @override
  Future<LocalFileStamp?> stamp(String path) async => stamps[path];
}

LocalFileStamp _stamp(int size, int mtime) =>
    LocalFileStamp(sizeBytes: size, modifiedAtMs: mtime);

void main() {
  setUp(LocalScanDiagnostics.reset);
  tearDown(LocalScanDiagnostics.reset);

  late _MutableScanner files;
  late _CountingMetadataReader tags;
  late _FakeStatReader stats;

  ProviderContainer container({
    List<String> roots = const <String>['/music'],
    InMemoryLocalTagRevisionStore? revisions,
  }) {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        if (revisions != null)
          localTagRevisionStoreProvider.overrideWithValue(revisions),
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService()),
        selectedMusicFolderRepositoryProvider.overrideWithValue(
          InMemorySelectedMusicFolderRepository(initialFolders: roots),
        ),
        // The real Drift repository over an in-memory SQLite instance: the
        // stamps have to survive an actual round trip through the schema, not
        // just through a fake that remembers whatever it was handed.
        linthraDatabaseExecutorProvider.overrideWithValue(
          NativeDatabase.memory(),
        ),
        driftMusicLibraryRepositoryOverride,
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
    files = _MutableScanner(<String, List<String>>{
      '/music': <String>['/music/a.flac', '/music/b.flac'],
    });
    tags = _CountingMetadataReader();
    stats = _FakeStatReader(<String, LocalFileStamp>{
      '/music/a.flac': _stamp(100, 1000),
      '/music/b.flac': _stamp(200, 2000),
    });
  });

  group('rescanning a library nobody touched', () {
    test('reads no tags the second time', () async {
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);

      await notifier.rescan();
      expect(tags.readCount, 2);
      expect(c.read(localScanReportProvider)?.parsedTracks, 2);

      tags.reads.clear();
      await notifier.rescan();

      expect(tags.readCount, 0);
      expect(c.read(localScanReportProvider)?.reusedTracks, 2);
      expect(c.read(localScanReportProvider)?.parsedTracks, 0);
    });

    test('the catalog is identical either way', () async {
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);

      await notifier.rescan();
      final List<String> first = (await c
              .read(musicLibraryRepositoryProvider)
              .getAllTracks())
          .map((Track t) => t.uri)
          .toList()
        ..sort();

      await notifier.rescan();
      final List<String> second = (await c
              .read(musicLibraryRepositoryProvider)
              .getAllTracks())
          .map((Track t) => t.uri)
          .toList()
        ..sort();

      expect(second, first);
      expect(second, <String>['/music/a.flac', '/music/b.flac']);
    });

    test('the stamps really went through SQLite', () async {
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();

      final LinthraDatabase db = c.read(linthraDatabaseProvider);
      final List<TrackRow> rows = await db.select(db.tracks).get();

      expect(rows, hasLength(2));
      for (final TrackRow row in rows) {
        expect(row.fileSizeBytes, isNotNull);
        expect(row.fileModifiedAtMs, isNotNull);
      }
    });
  });

  group('several folders', () {
    setUp(() {
      files = _MutableScanner(<String, List<String>>{
        '/music': <String>['/music/a.flac'],
        '/media/usb': <String>['/media/usb/b.flac'],
      });
      stats = _FakeStatReader(<String, LocalFileStamp>{
        '/music/a.flac': _stamp(100, 1000),
        '/media/usb/b.flac': _stamp(200, 2000),
      });
    });

    test('each folder skips its own unchanged files', () async {
      final ProviderContainer c =
          container(roots: <String>['/music', '/media/usb']);
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);

      await notifier.rescan();
      tags.reads.clear();
      await notifier.rescan();

      expect(tags.readCount, 0);
      expect(c.read(localScanReportProvider)?.reusedTracks, 2);
    });

    test('a changed file in one folder does not re-parse the other', () async {
      final ProviderContainer c =
          container(roots: <String>['/music', '/media/usb']);
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);

      await notifier.rescan();
      tags.reads.clear();
      stats.stamps['/media/usb/b.flac'] = _stamp(999, 9999);
      await notifier.rescan();

      expect(tags.reads, <String>['/media/usb/b.flac']);
    });

    test('an unavailable folder keeps its rows and its stamps', () async {
      final ProviderContainer c =
          container(roots: <String>['/music', '/media/usb']);
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);
      await notifier.rescan();

      // The drive is unplugged, then plugged back in.
      files.unavailable = <String>{'/media/usb'};
      await notifier.rescan();
      files.unavailable = <String>{};
      tags.reads.clear();
      await notifier.rescan();

      expect(
        (await c.read(musicLibraryRepositoryProvider).getAllTracks())
            .map((Track t) => t.uri)
            .toList()
          ..sort(),
        <String>['/media/usb/b.flac', '/music/a.flac'],
      );
      expect(
        tags.readCount,
        0,
        reason: 'the offline folder kept the stamps it was indexed with, so '
            'reconnecting the drive does not re-parse it',
      );
    });
  });

  group('a change to how tags are read (#783)', () {
    late _RevisedMetadataReader revised;
    late InMemoryLocalTagRevisionStore revisions;

    setUp(() {
      revised = _RevisedMetadataReader();
      tags = revised;
      revisions = InMemoryLocalTagRevisionStore();
    });

    test(
        'an update to the tag reader reads every file once more, then only '
        'what changed again', () async {
      final ProviderContainer c = container(revisions: revisions);
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);
      await notifier.rescan();
      revised.reads.clear();
      await notifier.rescan();
      expect(revised.readCount, 0);

      revised.tagRevision = 2;
      await notifier.rescan();
      expect(revised.readCount, 2,
          reason: 'unchanged on disk, but read by the old reader');
      expect(await revisions.load(), <String, int>{'/music': 2});

      revised.reads.clear();
      await notifier.rescan();
      expect(revised.readCount, 0);
    });

    test('a library indexed before revisions were recorded is read once',
        () async {
      final ProviderContainer c = container(revisions: revisions);
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);
      await notifier.rescan();
      // What a library indexed by an earlier version looks like: rows and
      // stamps in the catalog, and nothing recorded about how they were read.
      await revisions.save(const <String, int>{});
      revised.reads.clear();

      await notifier.rescan();

      expect(revised.readCount, 2);
      expect(await revisions.load(), <String, int>{'/music': 1});
    });

    test(
        'a file whose read fails that once keeps the row it had, not one '
        'built from its file name', () async {
      final ProviderContainer c = container(revisions: revisions);
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);
      await notifier.rescan();

      revised.tagRevision = 2;
      revised.failing = <String>{'/music/a.flac'};
      revised.reads.clear();
      await notifier.rescan();
      expect(revised.readCount, 2);

      final Track a =
          (await c.read(musicLibraryRepositoryProvider).getAllTracks())
              .singleWhere((Track t) => t.uri == '/music/a.flac');
      expect(a.title, 'Tagged',
          reason: 'it read fine before, and an unchanged file has the same '
              'tags');
      expect(a.artistName, 'Someone');
    });

    test('a folder no longer selected leaves no record behind', () async {
      files = _MutableScanner(<String, List<String>>{
        '/music': <String>['/music/a.flac'],
        '/media/usb': <String>['/media/usb/b.flac'],
      });
      final ProviderContainer c = container(
        roots: const <String>['/music', '/media/usb'],
        revisions: revisions,
      );
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();
      expect(
        await revisions.load(),
        <String, int>{'/music': 1, '/media/usb': 1},
      );

      await c
          .read(libraryControllerProvider.notifier)
          .scanFolders(<String>['/music']);

      expect(await revisions.load(), <String, int>{'/music': 1});
    });

    test('forgetting local music forgets the records too', () async {
      final ProviderContainer c = container(revisions: revisions);
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();
      expect(await revisions.load(), <String, int>{'/music': 1});

      await c.read(libraryControllerProvider.notifier).clearLocalCatalog();

      expect(await revisions.load(), isEmpty);
    });

    test(
        'a folder that could not be read is read in full once it can be, '
        'and only that one', () async {
      files = _MutableScanner(<String, List<String>>{
        '/music': <String>['/music/a.flac'],
        '/media/usb': <String>['/media/usb/b.flac'],
      });
      stats = _FakeStatReader(<String, LocalFileStamp>{
        '/music/a.flac': _stamp(100, 1000),
        '/media/usb/b.flac': _stamp(200, 2000),
      });
      final ProviderContainer c = container(
        roots: const <String>['/music', '/media/usb'],
        revisions: revisions,
      );
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);
      await notifier.rescan();

      // The update lands while the drive is out: only /music is read again.
      revised.tagRevision = 2;
      files.unavailable = <String>{'/media/usb'};
      revised.reads.clear();
      await notifier.rescan();
      expect(revised.reads, <String>['/music/a.flac']);
      expect(
        await revisions.load(),
        <String, int>{'/music': 2, '/media/usb': 1},
      );

      // The drive is back: its file was indexed by the old reader.
      files.unavailable = <String>{};
      revised.reads.clear();
      await notifier.rescan();
      expect(revised.reads, <String>['/media/usb/b.flac']);
      expect(
        await revisions.load(),
        <String, int>{'/music': 2, '/media/usb': 2},
      );
    });
  });

  group('recovery', () {
    test('a full rescan re-parses everything', () async {
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      await c.read(localMusicControllerProvider.notifier).rescan();
      tags.reads.clear();

      await c
          .read(libraryControllerProvider.notifier)
          .scanFolders(<String>['/music'], full: true);

      expect(tags.readCount, 2);
      expect(c.read(localScanReportProvider)?.reusedTracks, 0);
    });

    test('and leaves the library able to skip again afterwards', () async {
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);
      await notifier.rescan();
      await c
          .read(libraryControllerProvider.notifier)
          .scanFolders(<String>['/music'], full: true);

      tags.reads.clear();
      await notifier.rescan();

      expect(tags.readCount, 0);
    });

    test('forgetting the source drops the stamps with the rows', () async {
      final ProviderContainer c = container();
      await c.read(selectedFolderControllerProvider.future);
      final notifier = c.read(localMusicControllerProvider.notifier);
      await notifier.rescan();

      await notifier.forget();
      tags.reads.clear();
      await c
          .read(libraryControllerProvider.notifier)
          .scanFolders(<String>['/music']);

      expect(
        tags.readCount,
        2,
        reason: 'nothing is indexed any more, so nothing can be skipped',
      );
    });
  });
}
