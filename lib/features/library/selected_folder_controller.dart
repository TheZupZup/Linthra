import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sources/local/local_music_roots.dart';
import '../../data/repositories/selected_music_folder_repository_provider.dart';
import 'library_controller.dart';
import 'library_providers.dart';

/// Owns the user's chosen local-music locations: folder paths/SAF URIs, or an
/// app-defined source sentinel such as Android's device-wide MediaStore
/// library.
///
/// The state is an ordered list because a desktop library can span several
/// folders. Android puts exactly one entry in it — a SAF tree or the MediaStore
/// sentinel — so [setAndPersist] (replace everything) is the mutation it uses,
/// while desktop adds and removes folders one at a time.
class SelectedFolderController extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() {
    return ref.read(selectedMusicFolderRepositoryProvider).getSelectedFolders();
  }

  /// Opens the folder picker and, if the user chooses one, replaces the
  /// selection with it. Used where local music is a single choice: Android, and
  /// the first-run/empty-library prompts.
  Future<String?> pickAndPersist() async {
    final picked = await ref.read(folderPickerServiceProvider).pickFolder();
    if (picked == null || picked.isEmpty) {
      return null;
    }
    await setAndPersist(picked);
    return picked;
  }

  /// Opens the folder picker and adds the chosen folder to the selection,
  /// keeping the folders already there. Returns null when the user cancelled,
  /// and the folder itself otherwise — including when it changed nothing
  /// because it is already covered, which the caller reports rather than
  /// leaving the user wondering.
  Future<String?> pickAndAdd() async {
    final picked = await ref.read(folderPickerServiceProvider).pickFolder();
    if (picked == null || picked.isEmpty) {
      return null;
    }
    await addAndPersist(picked);
    return picked;
  }

  /// Persists a known local-library location as the only selection, without
  /// opening the folder picker. Used by Android's explicit device-wide
  /// MediaStore mode.
  Future<void> setAndPersist(String location) async {
    if (location.isEmpty) return;
    await _persist(<String>[location]);
  }

  /// Adds [location] to the selection, in the user's order. A folder that is
  /// already selected, or that sits inside one that is, is left out: it would
  /// scan the same files twice.
  Future<void> addAndPersist(String location) async {
    if (location.isEmpty) return;
    final List<String> current = state.valueOrNull ?? <String>[];
    await _persist(LocalMusicRoots.normalize(<String>[...current, location]));
  }

  /// Removes one folder from the selection, leaving the others alone.
  Future<void> removeAndPersist(String location) async {
    final List<String> current = state.valueOrNull ?? <String>[];
    final String target = LocalMusicRoots.canonicalize(location);
    final List<String> remaining = <String>[
      for (final String folder in current)
        if (LocalMusicRoots.canonicalize(folder) != target) folder,
    ];
    if (remaining.length == current.length) return;
    await _persist(remaining);
  }

  /// Forgets every selected folder.
  Future<void> clear() async {
    final library = ref.read(libraryControllerProvider.notifier);
    library.invalidatePendingScans();
    await library.waitForLocalMutations();
    await ref
        .read(selectedMusicFolderRepositoryProvider)
        .clearSelectedFolders();
    state = const AsyncData<List<String>>(<String>[]);
  }

  Future<void> _persist(List<String> folders) async {
    // A source change supersedes pending scans before persistence can yield.
    final library = ref.read(libraryControllerProvider.notifier);
    library.invalidatePendingScans();
    await library.waitForLocalMutations();
    await ref
        .read(selectedMusicFolderRepositoryProvider)
        .setSelectedFolders(folders);
    state = AsyncData<List<String>>(folders);
  }
}

final selectedFolderControllerProvider =
    AsyncNotifierProvider<SelectedFolderController, List<String>>(
  SelectedFolderController.new,
);
