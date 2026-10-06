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
import '../../core/sources/local/local_file_stat.dart';
import '../../core/sources/local/local_library_scanner.dart';
import '../../core/sources/local/local_metadata_reader.dart';
import '../../core/sources/local/local_music_roots.dart';
import '../../core/sources/local/local_music_source.dart';
import '../../core/sources/local/local_scan_report.dart';
import '../../data/repositories/favorites_repository_provider.dart';
import '../../data/repositories/local_tag_revision_store_provider.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../../data/repositories/play_history_repository_provider.dart';
import 'library_providers.dart';
import 'library_state.dart';
import 'local_root_availability_controller.dart';
import 'local_scan_report_provider.dart';
import 'selected_folder_controller.dart';

/// Drives the Library screen: loads tracks from the [MusicLibraryRepository]
/// and exposes them as a [LibraryState].
class LibraryController extends Notifier<LibraryState> {
  int _scanGeneration = 0;
  int _loadGeneration = 0;
  Future<void> _localMutationTail = Future<void>.value();

  /// Completes once every source change started through [changeSource] is
  /// done.
  Future<void> _sourceChanges = Future<void>.value();

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

  /// Runs [change], a source change that scans the new selection before it
  /// stores it (Reselect, switching to the device library), as one step that
  /// [refreshConfiguredFolders] does not start in the middle of.
  ///
  /// Such a change writes the catalog for a selection that is not stored yet,
  /// and only then stores it. A refresh of the stored selection that started
  /// in between superseded the scan, and the change was silently dropped; one
  /// that started after the scan had written the catalog then wrote a catalog
  /// for the old selection from that result, which no longer held the music of
  /// the folder being replaced, so a folder that was still selected lost its
  /// music; and one that started while the new selection was being saved read
  /// the old one, and dropped the music of the folder just picked.
  Future<T> changeSource<T>(Future<T> Function() change) {
    final Future<T> result = change();
    final Future<void> done = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    final Future<void> earlier = _sourceChanges;
    _sourceChanges = earlier.then((_) => done);
    return result;
  }

  /// Rescans the folders the user has configured, on the app's own initiative:
  /// the folder watcher runs this when a watched folder changes, and
  /// availability tracking when a drive comes back.
  ///
  /// It waits for a source change in progress ([changeSource]) and reads the
  /// selection only then, so it walks the folders that change stored rather
  /// than the ones it replaced. A user's own Rescan or Retry is not this: it
  /// supersedes whatever is running, as before.
  Future<void> refreshConfiguredFolders() async {
    Future<void> pending;
    do {
      pending = _sourceChanges;
      await pending;
    } while (!identical(pending, _sourceChanges));
    final List<String> roots =
        ref.read(selectedFolderControllerProvider).valueOrNull ??
            const <String>[];
    if (roots.isEmpty) return;
    await scanFolders(roots);
  }

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
  ///
  /// Fails when the catalog cannot be written (the disk is full, the database
  /// went read-only). The library is reloaded either way, so a scan
  /// superseded here never leaves it loading.
  Future<void> clearLocalCatalog() {
    invalidatePendingScans();
    return _serializeLocalMutation(() async {
      try {
        await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
          sourceId: _localSourceId,
          tracks: const [],
          albums: const [],
          artists: const [],
        );
        ref.read(localScanReportProvider.notifier).clear();
      } finally {
        await _load();
      }
    });
  }

  /// Takes the tracks of [folder], which the user just removed from the
  /// selection, out of the local catalog, after any already-started local
  /// write. Every other row stays exactly as it was, stamp included.
  ///
  /// The rescan of [remaining] that follows a removal drops them as well, but
  /// only when it can read one of those folders: a scan that reads nothing
  /// writes nothing. With the other drives unplugged, the removed folder's
  /// music would stay in the library under a folder that is no longer
  /// selected, with nothing left in Settings to remove it from.
  ///
  /// A row goes only when it is a path [folder] owns and no folder in
  /// [remaining] owns. A `content://` tree or the device-wide library cannot be
  /// matched to its rows by path, so removing one of those drops nothing here.
  ///
  /// Pending scans are superseded first, as [clearLocalCatalog] does, so a
  /// walk that started before the removal cannot write these tracks back. The
  /// catalog is reloaded either way, so a scan superseded here never leaves
  /// the library loading.
  Future<void> removeFolderTracks(
    String folder, {
    required List<String> remaining,
  }) {
    if (!FolderLocation.parse(folder).isFilesystemPath) {
      return Future<void>.value();
    }
    invalidatePendingScans();
    final List<String> stillSelected = LocalMusicRoots.normalize(remaining);
    return _serializeLocalMutation(() async {
      try {
        final List<StampedTrack>? current = await _localCatalogSnapshot();
        if (current != null) {
          final List<StampedTrack> kept = <StampedTrack>[
            for (final StampedTrack stamped in current)
              if (!LocalMusicRoots.owns(folder, stamped.track.uri) ||
                  LocalMusicRoots.ownerOf(stamped.track.uri, stillSelected) !=
                      null)
                stamped,
          ];
          if (kept.length < current.length) {
            final MusicLibraryRepository repository =
                ref.read(musicLibraryRepositoryProvider);
            if (repository is StampedCatalogWriter) {
              await (repository as StampedCatalogWriter).upsertStampedCatalog(
                sourceId: _localSourceId,
                tracks: kept,
              );
            } else {
              final List<Track> tracks = <Track>[
                for (final StampedTrack stamped in kept) stamped.track,
              ];
              await repository.upsertCatalog(
                sourceId: _localSourceId,
                tracks: tracks,
                albums: groupAlbums(tracks),
                artists: groupArtists(tracks),
              );
            }
          }
        }
      } catch (_) {
        // Left as it was. The rescan that follows still drops these tracks
        // as soon as one of the remaining folders can be read.
      }
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
  ///
  /// [acceptEmpty] names folders the user has said really are empty, so a walk
  /// that finds nothing there takes their music out (see
  /// [LocalLibraryScanner.scan]).
  Future<LocalScanReport?> scanFoldersWithReport(
    List<String> folderPaths, {
    bool full = false,
    Set<String> acceptEmpty = const <String>{},
  }) async {
    // Through invalidatePendingScans, so starting a scan also stops the native
    // walk it replaces. A SAF-to-SAF switch would supersede on its own (the
    // next listAudioDocuments trips the old flag), but switching to the
    // device-wide library never calls that, and the abandoned SAF walk would
    // otherwise do metadata and artwork I/O for the whole MediaStore traversal.
    invalidatePendingScans();
    final int generation = _scanGeneration;
    _showLoading();
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

      // Hoisted so the post-write artwork sweep below asks the *same* reader
      // that just populated the cache, rather than assuming which one the
      // provider hands out.
      final LocalMetadataReader metadataReader =
          ref.read(localMetadataReaderProvider);

      // A folder last read in full by another revision of the tag reader, or
      // never recorded, is read in full once more: unchanged files are never
      // opened again otherwise, so a change to how tags are read would only
      // ever reach new and edited ones (#783).
      final int? tagRevision = metadataReader is LocalTagRevision
          ? (metadataReader as LocalTagRevision).tagRevision
          : null;
      final Map<String, int>? readWith =
          tagRevision == null ? null : await _tagRevisions();
      if (generation != _scanGeneration) return null;
      final Set<String> rereadRoots = <String>{
        if (readWith != null)
          for (final String root in roots)
            if (readWith[root] != tagRevision) root,
      };

      // An unchanged file's row is reused as it is, cover included, so a
      // cover its cache no longer holds (the cache was reclaimed) would stay
      // missing for good. Those files are read again instead.
      final Set<Uri> missingArtwork =
          alreadyIndexed.isEmpty || metadataReader is! LocalArtworkInventory
              ? const <Uri>{}
              : await (metadataReader as LocalArtworkInventory).missingArtwork(
                  <Uri>{
                    for (final StampedTrack stamped in alreadyIndexed.values)
                      if (stamped.track.artworkUri != null)
                        stamped.track.artworkUri!,
                  },
                );
      if (generation != _scanGeneration) return null;

      final LocalFileStatReader statReader =
          ref.read(localFileStatReaderProvider);
      final scanner = LocalLibraryScanner(
        (String root) {
          return LocalMusicSource(
            folderPath: root,
            scanner: ref.read(audioFileScannerProvider),
            safDocumentLister: ref.read(safDocumentListerProvider),
            androidMediaLibrary: ref.read(androidMediaLibraryProvider),
            metadataReader: metadataReader,
            statReader: statReader,
            alreadyIndexed: rereadRoots.contains(root)
                ? const <String, StampedTrack>{}
                : alreadyIndexed,
            missingArtwork: missingArtwork,
          ).scanTracks();
        },
        // Lets a file moved while the walk ran be matched to where it went
        // (see LocalLibraryScanner._dropMovedAway). Only where paths are read.
        isGone: statReader is LocalFileAbsence
            ? (String path, String root) =>
                (statReader as LocalFileAbsence).isGone(path, root: root)
            : null,
      );
      final LocalLibraryScan scan = await scanner.scan(
        roots: roots,
        previousTracks: previousTracks,
        acceptEmpty: acceptEmpty,
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
          // Only when the walk itself diagnosed a folder, and only when the
          // folders it walked are the ones the user has configured. A scan that
          // read nothing for some other reason is not a folder problem, and a
          // trial of a source that is not committed yet (device music, a
          // replacement being checked before it is saved) is not the configured
          // library's problem either: offering its recovery would retry
          // something other than what failed.
          localRootsUnreadable:
              scan.report.fault != null && _isConfiguredSelection(roots),
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
        if (tagRevision != null && readWith != null) {
          await _recordTagRevision(readWith, scan, tagRevision);
        }
        // A newer action may have started while the write was awaiting I/O.
        // Its queued write will run after this one; do not publish stale status.
        if (generation != _scanGeneration) return null;

        // The catalog just written *is* the live set, so anything else in the
        // local artwork cache belongs to a file that has since been deleted,
        // moved, or re-tagged. Swept here and nowhere else, for two reasons:
        // this is the only point where the set is both complete (a folder that
        // could not be read contributed its retained tracks, and a scan that
        // lost even those never reaches here — see `scan.isWritable`) and
        // current (a superseded scan returned at the check above rather than
        // deleting covers a newer one had already written).
        //
        // Android's reader is not a LocalArtworkMaintainer, so this is a
        // no-op there and its SAF-side artwork cache is left entirely alone.
        if (metadataReader is LocalArtworkMaintainer) {
          await (metadataReader as LocalArtworkMaintainer).retainArtwork(
            <Uri>{
              for (final Track track in tracks)
                if (track.artworkUri != null) track.artworkUri!,
            },
          );
        }
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
        // Deliberately unset: this is a failure *outside* the folder walk (a
        // catalog write, most likely), so naming a filesystem fault for it
        // would tell the user to reconnect a drive that is sitting right there.
      );
      ref.read(localScanReportProvider.notifier).record(report);
      // The catalog write is one transaction, so a write that failed (a full
      // disk, a database gone read-only) left the catalog exactly as it was.
      // Show it, for the same reason a scan that could write nothing does:
      // an error page in its place says the music is gone, and its advice to
      // select the folder again would not help.
      await _showCatalogOrError(_scanFailedMessage);
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
      // With the reason attached, so the card explains an unmounted drive and a
      // permission problem differently without probing the folder a second time
      // to find out which it was.
      unreadableRoots: scan.rootFaults,
    );
  }

  /// Whether [roots] is the selection the user has actually configured, rather
  /// than a source being tried out before it is committed.
  bool _isConfiguredSelection(List<String> roots) {
    final List<String> selected = LocalMusicRoots.normalize(
      ref.read(selectedFolderControllerProvider).valueOrNull ??
          const <String>[],
    );
    final List<String> scanned = LocalMusicRoots.normalize(roots);
    if (selected.length != scanned.length) return false;
    for (int i = 0; i < selected.length; i++) {
      if (selected[i] != scanned[i]) return false;
    }
    return true;
  }

  /// Publishes whatever the catalog holds, falling back to [message] only when
  /// there is nothing at all to show.
  ///
  /// Used by the scans that write nothing. Every source is included, so a local
  /// drive going away cannot blank a Jellyfin or Navidrome library either.
  Future<void> _showCatalogOrError(
    String message, {
    bool localRootsUnreadable = false,
  }) async {
    final int generation = ++_loadGeneration;
    try {
      final List<Track> tracks =
          await ref.read(musicLibraryRepositoryProvider).getAllTracks();
      if (generation != _loadGeneration) return;
      state = tracks.isEmpty
          ? LibraryState.error(message,
              localRootsUnreadable: localRootsUnreadable)
          : LibraryState.loaded(tracks);
    } catch (_) {
      // The catalog would not answer either. That failure is this one's, not
      // the folder's, so it keeps its own message and its own retry.
      if (generation == _loadGeneration) state = LibraryState.error(message);
    }
  }

  /// Which tag-reader revision each folder was last read in full with, or
  /// null when that can't be read: nothing is then read in full on its
  /// account, and nothing recorded.
  Future<Map<String, int>?> _tagRevisions() async {
    try {
      return await ref.read(localTagRevisionStoreProvider).load();
    } catch (_) {
      return null;
    }
  }

  /// Records [revision] for every folder [scan] could read, which it read in
  /// full if it was due, keeping what [recorded] says for the others: a
  /// folder that couldn't be read keeps its old rows, and is read in full
  /// once it can be.
  Future<void> _recordTagRevision(
    Map<String, int> recorded,
    LocalLibraryScan scan,
    int revision,
  ) async {
    final Map<String, int> next = <String, int>{
      ...recorded,
      for (final LocalRootOutcome outcome in scan.roots)
        if (outcome.available) outcome.root: revision,
    };
    if (next.length == recorded.length &&
        next.keys.every((String root) => recorded[root] == next[root])) {
      return;
    }
    try {
      await ref.read(localTagRevisionStoreProvider).save(next);
    } catch (_) {
      // Not recorded: those folders are read in full once more next time.
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

  /// Shows the loading state, unless the library already has music on screen.
  ///
  /// A rescan or a reload replaces what is shown only once its new catalog is
  /// ready. Blanking the library for the length of a walk hid every track,
  /// local and server alike, behind "Loading your library" whenever the folder
  /// watcher or a returning drive started a rescan, and threw away the scroll
  /// position of every list and album page the user was reading. A walk that
  /// never answers (a network share whose server went away) never gave the
  /// library back at all. With nothing shown yet there is nothing to keep, so
  /// the first load still shows the spinner.
  void _showLoading() {
    final LibraryState? shown = stateOrNull;
    if (shown != null &&
        shown.status == LibraryStatus.loaded &&
        shown.tracks.isNotEmpty) {
      return;
    }
    state = const LibraryState.loading();
  }

  Future<void> _load() async {
    final int generation = ++_loadGeneration;
    _showLoading();
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
