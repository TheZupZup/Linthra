import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/selected_music_folder_repository.dart';
import 'in_memory_selected_music_folder_repository.dart';
import 'shared_preferences_selected_music_folder_repository.dart';

/// The single [SelectedMusicFolderRepository] the app reads the chosen music
/// folder from.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins (no `shared_preferences`). The running app overrides
/// this with [sharedPreferencesSelectedMusicFolderRepositoryOverride] so the
/// selection persists across restarts.
final selectedMusicFolderRepositoryProvider =
    Provider<SelectedMusicFolderRepository>((ref) {
  return InMemorySelectedMusicFolderRepository();
});

/// Production binding: persists the selected folder via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesSelectedMusicFolderRepositoryOverride =
    selectedMusicFolderRepositoryProvider.overrideWithValue(
  const SharedPreferencesSelectedMusicFolderRepository(),
);
