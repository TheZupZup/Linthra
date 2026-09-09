import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/selected_music_folder_repository.dart';

/// A [SelectedMusicFolderRepository] backed by `shared_preferences`.
///
/// The selection is a handful of short strings, so a key/value store is the
/// right weight here — no need to involve the SQLite catalog. The plugin is
/// touched lazily on first call, so constructing this object is cheap and never
/// blocks app start.
///
/// Two keys are written, on purpose:
///
///  * [_foldersKey] holds the real, ordered selection.
///  * [_legacyFolderKey] is the single-folder key builds before multi-folder
///    support wrote. It is still read, so an existing user's folder is picked
///    up as their first folder with nothing to migrate explicitly, and still
///    written with the first folder, so downgrading to an older build finds the
///    selection it expects instead of an empty library.
class SharedPreferencesSelectedMusicFolderRepository
    implements SelectedMusicFolderRepository {
  const SharedPreferencesSelectedMusicFolderRepository();

  static const String _foldersKey = 'selected_music_folders';
  static const String _legacyFolderKey = 'selected_music_folder';

  @override
  Future<List<String>> getSelectedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? folders = prefs.getStringList(_foldersKey);
    if (folders != null) {
      return <String>[
        for (final String folder in folders)
          if (folder.isNotEmpty) folder,
      ];
    }
    // Never wrote the list yet: this install last ran a single-folder build.
    final String? legacy = prefs.getString(_legacyFolderKey);
    return (legacy == null || legacy.isEmpty) ? <String>[] : <String>[legacy];
  }

  @override
  Future<void> setSelectedFolders(List<String> pathsOrUris) async {
    final List<String> folders = <String>[
      for (final String folder in pathsOrUris)
        if (folder.isNotEmpty) folder,
    ];
    if (folders.isEmpty) {
      await clearSelectedFolders();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_foldersKey, folders);
    await prefs.setString(_legacyFolderKey, folders.first);
  }

  @override
  Future<void> clearSelectedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_foldersKey);
    await prefs.remove(_legacyFolderKey);
  }
}
