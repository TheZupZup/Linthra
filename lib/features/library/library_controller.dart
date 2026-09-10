import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/library_grouping.dart';
import '../../core/models/track.dart';
import '../../core/repositories/music_library_repository.dart';
import '../../core/repositories/source_catalog_reader.dart';
import '../../core/services/local_track_move_applier.dart';
import '../../core/sources/local/folder_location.dart';
import '../../core/sources/local/local_library_scanner.dart';
import '../../core/sources/local/local_music_roots.dart';
import '../../core/sources/local/local_music_source.dart';
import '../../core/sources/local/local_scan_report.dart';
import '../../data/repositories/favorites_repository_provider.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../../data/repositories/play_history_repository_provider.dart';
import 'library_providers.dart';
import 'library_state.dart';
import 'local_scan_report_provider.dart';

/// Drives the Library screen: loads tracks from the [MusicLibraryRepository]
/// and exposes them as a [LibraryState].
class LibraryController extends Notifier<LibraryState> {
  int _scanGeneration = 0;
  int _loadGeneration = 0;
  Future<void> _localMutationTail = Future<void>.value();

  @override
  LibraryState build() {
    _load();
    return const LibraryState.loading();
  }

  /// Reloading the shared catalog must not cancel an unrelated local scan.
  Future<void> refresh() => _load();

  /// Supersedes pending local scans when the user changes or forgets a source,
  /// and when one starts. Call this before the first asynchronous part of the
  /// source mutation.
  ///
  /// Bumping the generations makes an in-flight scan's result unusable, but on
  /// Android it does not stop the native SAF walk producing it: that keeps
  /// opening a metadata retriever and extracting artwork for the rest of an
  /// abandoned library, competing for content-resolver I/O with whatever the
  /// user switched to.
  ///
  /// Only a new `listAudioDocuments` supersedes a walk natively, so every other
  /// way to abandon one needs this: forgetting the folder, clearing the local
  /// catalog, and starting a scan of the device-wide library (which goes to
  /// MediaStore, never through the SAF channel). This is why the bump lives
  /// here rather than being written out at each call site.
  ///
  /// Deliberately not awaited: this must stay synchronous so callers can
  /// invalidate before their first `await`, and cancellation is best-effort on
  /// every platform. The generation guard remains the thing that makes the
  /// result safe; this only saves the work.
  void invalidatePendingScans() {
    _scanGeneration++;
    _loadGeneration++;
    unawaited(ref.read(safDocumentListerProvider).cancelScan());
  }

  /// Waits for already-started local writes before persisting a source change.
  /// Invalidation happens first, so pending walks cannot enqueue a new write.
  Future<void> waitForLocalMutations() => _localMutationTail;

  /// Serializes local catalog writes, including forget. A scan may finish its
  /// walk while a previous write is pending; its generation is checked again
  /// inside this queue so obsolete results cannot commit after a clear.
  Future<T> _serializeLocalMutation<T>(Future<T> Function() operation) {
    final Future<T> result = _localMutationTail.then((_) => operation());
    _localMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Clears only the local source, after any already-started local write.
  /// A new scan started after this action can still populate the catalog.
  Future<void> clearLocalCatalog() {
    invalidatePendingScans();
    return _serializeLocalMutation(() async {
      await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
        sourceId: _localSourceId,
        tracks: const [],
        albums: const [],
        artists: const [],
      );
      ref.read(localScanReportProvider.notifier).clear();
      await _load();
    });
  }

  /// Scans a filesystem folder, SAF tree, or Android device-wide MediaStore
  /// selection, persists the discovered tracks, then reloads the catalog.
  /// Kept as a void-returning API for existing Library screen callers.
  Future<void> scanFolder(String folderPath) async {
    await scanFolderWithReport(folderPath);
  }

  /// Returns this operation's report, or null if it was superseded. Callers
  /// must not infer success from the last globally recorded scan report.
  Future<LocalScanReport?> scanFolderWithReport(String folderPath) {
    return scanFoldersWithReport(<String>[folderPath]);
  }

  /// Scans every selected local folder and replaces the local catalog with what
  /// they hold together.
  Future<void> scanFolders(List<String> folderPaths) async {
    await scanFoldersWithReport(folderPaths);
  }

  /// Scans [folderPaths] as one library and returns the merged report, or null
  /// if the scan was superseded.
  ///
  /// Folders are scanned independently and merged, which is what makes several
  /// music folders behave like one library: overlapping folders import a file
  /// once, and a folder that is offline right now keeps the tracks it already
  /// contributed instead of having them deleted along with the refresh of the
  /// folders that *are* readable. A scan that could read nothing at all — or
  /// that could not read back what an offline folder had indexed — writes
  /// nothing, exactly as a failed single-folder scan always has.
  Future<LocalScanReport?> scanFoldersWithReport(
    List<String> folderPaths,
  ) async {
    // Through invalidatePendingScans, so starting a scan also stops the native
    // walk it replaces. A SAF-to-SAF switch would supersede on its own (the
    // next listAudioDocuments trips the old flag), but switching to the
    // device-wide library never calls that, and the abandoned SAF walk would
    // otherwise do metadata and artwork I/O for the whole MediaStore traversal.
    invalidatePendingScans();
    final int generation = _scanGeneration;
    state = const LibraryState.loading();
    final List<String> roots = LocalMusicRoots.normalize(folderPaths);
    try {
      // Read back what the local slice holds today. Two things need it: an
      // offline folder's tracks have to be carried into the new slice, and a
      // file that changed path can only be recognised as *the same file* by
      // comparing against what was there before. It used to be fetched only for
      // a multi-folder library, because retention was the only use; move
      // detection makes it worth one indexed query on every scan.
      final List<Track>? previousTracks = await _localCatalogSnapshot();
      if (generation != _scanGeneration) return null;

      final scanner = LocalLibraryScanner((String root) {
        return LocalMusicSource(
          folderPath: root,
          scanner: ref.read(audioFileScannerProvider),
          safDocumentLister: ref.read(safDocumentListerProvider),
          androidMediaLibrary: ref.read(androidMediaLibraryProvider),
          metadataReader: ref.read(localMetadataReaderProvider),
        ).scanTracks();
      });
      final LocalLibraryScan scan = await scanner.scan(
        roots: roots,
        previousTracks: previousTracks,
      );
      if (generation != _scanGeneration) return null;

      if (!scan.isWritable) {
        ref.read(localScanReportProvider.notifier).record(scan.report);
        _loadGeneration++;
        state = LibraryState.error(
          scan.firstFailureMessage ?? _scanFailedMessage,
        );
        return scan.report;
      }

      return await _serializeLocalMutation<LocalScanReport?>(() async {
        // Check at commit time, not merely when the filesystem walk finishes.
        if (generation != _scanGeneration) return null;
        final repository = ref.read(musicLibraryRepositoryProvider);
        // Before the write, never after: the catalog write stamps any uri it
        // has not seen before as newly added, so the moved file's real "added
        // on" date has to be carried across first.
        await LocalTrackMoveApplier(<Object>[
          repository,
          ref.read(favoritesRepositoryProvider),
          ref.read(playHistoryRepositoryProvider),
        ]).apply(scan.reconciliation);
        await repository.upsertCatalog(
          sourceId: _localSourceId,
          tracks: scan.tracks,
          albums: groupAlbums(scan.tracks),
          artists: groupArtists(scan.tracks),
        );
        // A newer action may have started while the write was awaiting I/O.
        // Its queued write will run after this one; do not publish stale status.
        if (generation != _scanGeneration) return null;
        ref.read(localScanReportProvider.notifier).record(scan.report);
        await _load();
        return generation == _scanGeneration ? scan.report : null;
      });
    } catch (_) {
      // Whatever failed here is outside the per-folder scan (the catalog write,
      // most likely): every folder failure is already classified and merged by
      // the scanner. A single selection still reports its kind, so the recovery
      // advice keeps pointing at the right place.
      if (generation != _scanGeneration) return null;
      final FolderLocation? only =
          roots.length == 1 ? FolderLocation.parse(roots.single) : null;
      final report = LocalScanReport.failure(
        folderSelected: roots.isNotEmpty,
        isContentUri: only?.isContentUri ?? false,
        isDeviceLibrary: only?.isAndroidMediaStore ?? false,
        error: LocalScanError.unexpected,
        rootsScanned: roots.length,
        rootsUnavailable: roots.length,
      );
      ref.read(localScanReportProvider.notifier).record(report);
      _loadGeneration++;
      state = const LibraryState.error(_scanFailedMessage);
      return report;
    }
  }

  /// The local slice of the catalog as it stands, or null when this repository
  /// cannot read a source's slice. Null means "unknown", never "empty": the
  /// scan uses it to decide whether it may overwrite the local slice, and
  /// mistaking one for the other would delete an offline folder's music.
  Future<List<Track>?> _localCatalogSnapshot() async {
    final MusicLibraryRepository repository =
        ref.read(musicLibraryRepositoryProvider);
    if (repository is! SourceCatalogReader) return null;
    try {
      return await (repository as SourceCatalogReader)
          .getTracksForSource(_localSourceId);
    } catch (_) {
      return null;
    }
  }

  static const String _localSourceId = 'local';

  static const String _scanFailedMessage =
      "Couldn't scan that folder. Try selecting it again, or pick a different "
      'folder.';

  static const String _loadFailedMessage =
      "Couldn't open your music library. Try again, or rescan your music "
      'folder.';

  Future<void> _load() async {
    final int generation = ++_loadGeneration;
    state = const LibraryState.loading();
    try {
      final tracks =
          await ref.read(musicLibraryRepositoryProvider).getAllTracks();
      if (generation == _loadGeneration) {
        state = LibraryState.loaded(tracks);
      }
    } catch (_) {
      if (generation == _loadGeneration) {
        state = const LibraryState.error(_loadFailedMessage);
      }
    }
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
