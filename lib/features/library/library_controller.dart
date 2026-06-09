import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/library_grouping.dart';
import '../../core/sources/local/folder_location.dart';
import '../../core/sources/local/folder_scan_exception.dart';
import '../../core/sources/local/local_music_source.dart';
import '../../core/sources/local/local_scan_report.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import 'library_providers.dart';
import 'library_state.dart';
import 'local_scan_report_provider.dart';

/// Drives the Library screen: loads tracks from the [MusicLibraryRepository]
/// and exposes them as a [LibraryState]. Keeps the UI free of any direct
/// knowledge of the repository or its backing store.
class LibraryController extends Notifier<LibraryState> {
  @override
  LibraryState build() {
    // Kick off the initial load; the screen shows a spinner until it lands.
    _load();
    return const LibraryState.loading();
  }

  /// Re-reads the catalog. Safe to call again (e.g. after a scan).
  Future<void> refresh() => _load();

  /// Scans [folderPath] with a [LocalMusicSource], persists the discovered
  /// tracks through the [MusicLibraryRepository], then reloads so the screen
  /// shows what was just stored. Any failure surfaces as an error state.
  Future<void> scanFolder(String folderPath) async {
    state = const LibraryState.loading();
    final FolderLocation location = FolderLocation.parse(folderPath);
    try {
      final source = LocalMusicSource(
        folderPath: folderPath,
        scanner: ref.read(audioFileScannerProvider),
        safDocumentLister: ref.read(safDocumentListerProvider),
        metadataReader: ref.read(localMetadataReaderProvider),
      );
      final LocalScan scan = await source.scanTracks();
      final repository = ref.read(musicLibraryRepositoryProvider);
      // Derive the album/artist groupings from the just-scanned tracks rather
      // than re-scanning the folder (which would re-read every file's tags); the
      // unified library derives its own groupings from the stored tracks the same
      // way, so this only feeds repositories that persist them.
      await repository.upsertCatalog(
        sourceId: source.id,
        tracks: scan.tracks,
        albums: groupAlbums(scan.tracks),
        artists: groupArtists(scan.tracks),
      );
      // Record the counts (visited / folders / audio / imported / skipped /
      // read failures) so a "no music found" report can show what the scan
      // actually saw — reactively (Settings ▸ Local music) and in diagnostics.
      ref.read(localScanReportProvider.notifier).record(scan.report);
      await _load();
    } on FolderScanException catch (error) {
      // The scanning layer already phrased a clear, secret-free message
      // (unreachable SAF tree, unreadable scoped-storage path, …); show it.
      ref.read(localScanReportProvider.notifier).record(LocalScanReport.failure(
            folderSelected: folderPath.isNotEmpty,
            isContentUri: location.isContentUri,
            error: LocalScanError.safTraversal,
          ));
      state = LibraryState.error(error.message);
    } catch (_) {
      // Anything else is an unexpected scan failure — a raw `dart:io`
      // permission error or a plugin fault. Don't leak its text (errno codes,
      // paths) to the user; show one friendly, actionable line instead.
      ref.read(localScanReportProvider.notifier).record(LocalScanReport.failure(
            folderSelected: folderPath.isNotEmpty,
            isContentUri: location.isContentUri,
            error: LocalScanError.unexpected,
          ));
      state = const LibraryState.error(_scanFailedMessage);
    }
  }

  static const String _scanFailedMessage =
      "Couldn't scan that folder. Try selecting it again, or pick a different "
      'folder.';

  static const String _loadFailedMessage =
      "Couldn't open your music library. Try again, or rescan your music "
      'folder.';

  Future<void> _load() async {
    state = const LibraryState.loading();
    try {
      final tracks =
          await ref.read(musicLibraryRepositoryProvider).getAllTracks();
      state = LibraryState.loaded(tracks);
    } catch (_) {
      // Don't leak raw store/exception text (file paths, SQL, errno) to the
      // UI; show one friendly, actionable line instead.
      state = const LibraryState.error(_loadFailedMessage);
    }
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
