import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/selected_music_folder_repository_provider.dart';
import 'library_providers.dart';

/// Owns the user's chosen music folder: loads the persisted selection, lets the
/// user pick a new one, and persists the result.
///
/// Deliberately separate from the library controller/scanning — this only
/// answers "which folder did the user choose?". The screen combines it with the
/// scan flow. State is the selected folder path/URI, or `null` when none is set.
class SelectedFolderController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() {
    return ref.read(selectedMusicFolderRepositoryProvider).getSelectedFolder();
  }

  /// Opens the folder picker and, if the user chooses one, persists it and
  /// updates state. Returns the chosen folder, or `null` when cancelled (state
  /// is left unchanged in that case).
  Future<String?> pickAndPersist() async {
    final picked = await ref.read(folderPickerServiceProvider).pickFolder();
    if (picked == null || picked.isEmpty) {
      return null;
    }
    await ref
        .read(selectedMusicFolderRepositoryProvider)
        .setSelectedFolder(picked);
    state = AsyncData<String?>(picked);
    return picked;
  }

  /// Forgets the current selection.
  Future<void> clear() async {
    await ref.read(selectedMusicFolderRepositoryProvider).clearSelectedFolder();
    state = const AsyncData<String?>(null);
  }
}

final selectedFolderControllerProvider =
    AsyncNotifierProvider<SelectedFolderController, String?>(
  SelectedFolderController.new,
);
