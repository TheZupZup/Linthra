import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/library_grouping.dart';
import '../../core/models/local_file_stamp.dart';
import '../../core/models/track.dart';
import '../../core/repositories/music_library_repository.dart';
import '../../core/repositories/source_catalog_reader.dart';
import '../../core/repositories/stamped_catalog_writer.dart';
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
import 'local_root_availability_controller.dart';
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
  Future<LocalScanReport?> scanFolderWithReport(
    String folderPath, {
    bool full = false,
  }) {
    return scanFoldersWithReport(<String>[folderPath], full: full);
  }

  /// Scans every selected local folder and replaces the local catalog with what
  /// they hold together.
  Future<void> scanFolders(List<String> folderPaths,
      {bool full = false}) async {
    await scanFoldersWithReport(folderPaths, full: full);
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
  /// Pass [full] to re-parse every file regardless of whether it looks
  /// unchanged. This is the recovery path: an ordinary scan trusts each file's
  /// size and mtime, and a write that restores both (a backup tool putting an
  /// old file back, `touch -r` after an in-place edit) would otherwise go
  /// unnoticed. It is also the honest answer to "the library looks wrong",
  /// since it rebuilds the whole slice from the files themselves.
  Future<LocalScanReport?> scanFoldersWithReport(
    List<String> folderPaths, {
    bool full = false,
  }) async {
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
      // The stored slice, with each row's on-disk stamp. Three jobs: an
      // offline folder's tracks are carried into the new slice, a file whose
      // stamp is unchanged is reused instead of being opened and parsed again,
      // and a file that changed path can only be recognised as *the same file*
      // by comparing against what was there before. It used to be fetched only
      // for a multi-folder library, because retention was the only use; the
      // other two make it worth one indexed query on every scan.
      final List<StampedTrack>? previousTracks = await _localCatalogSnapshot();
      if (generation != _scanGeneration) return null;

      // A full rescan simply looks at nothing: with no known stamp, every file
      // falls through to the parse. It is the same code path, which is what
      // keeps the two from drifting apart.
      final Map<String, StampedTrack> alreadyIndexed = full
          ? const <String, StampedTrack>{}
          : <String, StampedTrack>{
              for (final StampedTrack stamped in previousTracks ?? const [])
                stamped.track.uri: stamped,
            };

      final scanner = LocalLibraryScanner((String root) {
        return LocalMusicSource(
          folderPath: root,
          scanner: ref.read(audioFileScannerProvider),
          safDocumentLister: ref.read(safDocumentListerProvider),
          androidMediaLibrary: ref.read(androidMediaLibraryProvider),
          metadataReader: ref.read(localMetadataReaderProvider),
          statReader: ref.read(localFileStatReaderProvider),
          alreadyIndexed: alreadyIndexed,
        ).scanTracks();
      });
      final LocalLibraryScan scan = await scanner.scan(
        roots: roots,
        previousTracks: previousTracks,
      );
      if (generation != _scanGeneration) return null;

      _noteRootOutcomes(scan);

      if (!scan.isWritable) {
        ref.read(localScanReportProvider.notifier).record(scan.report);
        // Nothing was written, so the catalog still holds exactly what it held
        // before. Show it. A drive that is unplugged, or a folder that went away
        // while the watcher was refreshing, is not a broken library, and
        // replacing the user's music with an error page is the screen's way of
        // saying "it's gone", which is the one thing this must never imply. The
        // failure is still reported: the scan report drives the Local music
        // card's message and the diagnostics line.
        //
        // With nothing indexed at all the message *is* the whole answer, so
        // that case keeps the error state.
        await _showCatalogOrError(
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
        final List<Track> tracks = scan.plainTracks;
        if (repository is StampedCatalogWriter) {
          // Same write, plus the stamps a later scan compares against. Without
          // them every scan re-parses everything, which is correct but is the
          // cost this exists to remove.
          await (repository as StampedCatalogWriter).upsertStampedCatalog(
            sourceId: _localSourceId,
            tracks: scan.tracks,
          );
        } else {
          await repository.upsertCatalog(
            sourceId: _localSourceId,
            tracks: tracks,
            albums: groupAlbums(tracks),
            artists: groupArtists(tracks),
          );
        }
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

  /// Tells availability tracking which folders this scan could read and which
  /// it could not.
  ///
  /// A scan walked those folders, so it knows more than any probe can and it
  /// knows it without a second syscall: a folder that answered with files is
  /// there, and one that threw is not reachable right now. Availability turns
  /// that into the per-folder state the UI reads, and into nothing else, because
  /// a folder that cannot be read is never a folder to forget.
  void _noteRootOutcomes(LocalLibraryScan scan) {
    if (scan.roots.isEmpty) return;
    ref.read(localRootAvailabilityProvider.notifier).noteScanOutcome(
      readRoots: <String>[
        for (final LocalRootOutcome outcome in scan.roots)
          if (outcome.available) outcome.root,
      ],
      unreadableRoots: <String>[
        for (final LocalRootOutcome outcome in scan.roots)
          if (!outcome.available) outcome.root,
      ],
    );
  }

  /// Publishes whatever the catalog holds, falling back to [message] only when
  /// there is nothing at all to show.
  ///
  /// Used by the scans that write nothing. Every source is included, so a local
  /// drive going away cannot blank a Jellyfin or Navidrome library either.
  Future<void> _showCatalogOrError(String message) async {
    final int generation = ++_loadGeneration;
    try {
      final List<Track> tracks =
          await ref.read(musicLibraryRepositoryProvider).getAllTracks();
      if (generation != _loadGeneration) return;
      state = tracks.isEmpty
          ? LibraryState.error(message)
          : LibraryState.loaded(tracks);
    } catch (_) {
      if (generation == _loadGeneration) state = LibraryState.error(message);
    }
  }

  /// The local slice of the catalog as it stands, with each row's on-disk
  /// stamp, or null when this repository cannot read a source's slice.
  ///
  /// Null means "unknown", never "empty": the scan uses it to decide whether it
  /// may overwrite the local slice, and mistaking one for the other would
  /// delete an offline folder's music. A repository that can read a slice but
  /// cannot store stamps answers with unstamped tracks, so retention still
  /// works and every file is simply parsed.
  Future<List<StampedTrack>?> _localCatalogSnapshot() async {
    final MusicLibraryRepository repository =
        ref.read(musicLibraryRepositoryProvider);
    try {
      if (repository is StampedCatalogWriter) {
        return await (repository as StampedCatalogWriter)
            .getStampedTracksForSource(_localSourceId);
      }
      if (repository is SourceCatalogReader) {
        final List<Track> tracks = await (repository as SourceCatalogReader)
            .getTracksForSource(_localSourceId);
        return <StampedTrack>[
          for (final Track track in tracks) StampedTrack(track: track),
        ];
      }
      return null;
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
