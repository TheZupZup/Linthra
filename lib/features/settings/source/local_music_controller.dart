import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_music_source.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../library/library_controller.dart';
import '../../library/library_providers.dart';
import '../../library/local_scan_report_provider.dart';
import '../../library/selected_folder_controller.dart';

/// Transient state for the Settings ▸ Local music card: whether an action is
/// running and the last one-line outcome to surface.
class LocalMusicActionState {
  const LocalMusicActionState({
    this.busy = false,
    this.message,
    this.isError = false,
  });

  /// True while a pick/rescan/forget is in flight (drives the spinner).
  final bool busy;

  /// A short, secret-free outcome line for the card, or null when there's
  /// nothing to say. Never a path or file name.
  final String? message;

  /// Whether [message] reports a failure (rendered in the error colour).
  final bool isError;
}

/// Drives the Settings ▸ Local music source card: choose a folder, rescan it,
/// or forget it. It is the source-shaped peer of the Jellyfin/Subsonic settings
/// controllers, and the configuration home the empty-state "Change folder"
/// button mirrors.
///
/// It owns no scanning logic of its own — it reuses the same pick/scan path the
/// Library screen uses ([SelectedFolderController] + [LibraryController]) so a
/// folder configured here and one configured from the Library behave
/// identically and both refresh the catalog. The selected folder and the last
/// scan counts are read reactively from their own providers by the widget; this
/// controller only carries the in-flight/outcome state and the actions.
class LocalMusicController extends Notifier<LocalMusicActionState> {
  @override
  LocalMusicActionState build() => const LocalMusicActionState();

  /// Opens the folder chooser, persists the choice, and scans it. On Android
  /// this returns a `content://` tree URI with a persisted read grant — the
  /// scoped-storage-correct selection. A cancelled pick leaves everything as it
  /// was.
  Future<void> pickFolder() async {
    state = const LocalMusicActionState(busy: true);
    final String? picked = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndPersist();
    if (picked == null || picked.isEmpty) {
      // Cancelled — say nothing, change nothing.
      state = const LocalMusicActionState();
      return;
    }
    await _scan(picked);
  }

  /// Re-scans the folder already selected, without opening the chooser. No-op
  /// when nothing is selected yet.
  Future<void> rescan() async {
    final String? folder =
        ref.read(selectedFolderControllerProvider).valueOrNull;
    if (folder == null || folder.isEmpty) {
      return;
    }
    state = const LocalMusicActionState(busy: true);
    await _scan(folder);
  }

  /// Forgets the selected folder and removes the local tracks from the catalog.
  /// Deletes nothing on disk — it only clears Linthra's index for the `local`
  /// source, so re-selecting the folder brings everything back.
  Future<void> forget() async {
    state = const LocalMusicActionState(busy: true);
    await ref.read(selectedFolderControllerProvider.notifier).clear();
    await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
      sourceId: const LocalMusicSource(folderPath: null).id,
      tracks: const [],
      albums: const [],
      artists: const [],
    );
    ref.read(localScanReportProvider.notifier).clear();
    await ref.read(libraryControllerProvider.notifier).refresh();
    state = const LocalMusicActionState(
      message: 'Local folder forgotten. Your files were not deleted.',
    );
  }

  /// Runs the shared scan-and-persist path, then summarizes the outcome from the
  /// recorded scan report (counts only — never a path or file name).
  Future<void> _scan(String folder) async {
    await ref.read(libraryControllerProvider.notifier).scanFolder(folder);
    final report = ref.read(localScanReportProvider);
    final bool isContentUri = FolderLocation.parse(folder).isContentUri;
    if (report == null) {
      state = const LocalMusicActionState();
      return;
    }
    if (report.hadError) {
      state = const LocalMusicActionState(
        message: "Couldn't scan that folder. Try selecting it again.",
        isError: true,
      );
      return;
    }
    if (report.importedTracks > 0) {
      state = LocalMusicActionState(
        message: 'Added ${report.importedTracks} '
            '${report.importedTracks == 1 ? 'track' : 'tracks'} from this '
            'folder.',
      );
      return;
    }
    // Completed, but nothing playable. Distinguish a likely access problem from
    // a genuinely empty folder so the message is actionable.
    final bool looksBlocked =
        report.readFailures > 0 || (isContentUri && report.filesVisited == 0);
    state = LocalMusicActionState(
      message: looksBlocked
          ? 'No music found. Linthra may not have access to that folder — try '
              'selecting it again.'
          : 'No playable audio found in that folder.',
      isError: looksBlocked,
    );
  }
}

final localMusicControllerProvider =
    NotifierProvider<LocalMusicController, LocalMusicActionState>(
  LocalMusicController.new,
);

/// Whether Linthra still holds a persisted read grant for the selected
/// `content://` folder — the removable-SD-card / lost-access signal shown on the
/// Local music card. Re-evaluated whenever the selection changes.
///
/// Returns `null` when it doesn't apply (no folder, or a plain filesystem path)
/// or can't be determined (off Android), so the card simply omits the line.
final localFolderAccessProvider = FutureProvider<bool?>((ref) async {
  final String? folder =
      ref.watch(selectedFolderControllerProvider).valueOrNull;
  if (folder == null || folder.isEmpty) {
    return null;
  }
  if (!FolderLocation.parse(folder).isContentUri) {
    return null;
  }
  return ref.read(safPermissionProbeProvider).hasPersistedPermission(folder);
});
