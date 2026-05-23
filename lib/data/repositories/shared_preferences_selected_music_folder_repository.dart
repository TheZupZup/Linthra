import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/selected_music_folder_repository.dart';

/// A [SelectedMusicFolderRepository] backed by `shared_preferences`.
///
/// The selected folder is a single small string, so a key/value store is the
/// right weight here — no need to involve the SQLite catalog. The plugin is
/// touched lazily on first call, so constructing this object is cheap and never
/// blocks app start.
class SharedPreferencesSelectedMusicFolderRepository
    implements SelectedMusicFolderRepository {
  const SharedPreferencesSelectedMusicFolderRepository();

  static const String _key = 'selected_music_folder';

  @override
  Future<String?> getSelectedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return (value == null || value.isEmpty) ? null : value;
  }

  @override
  Future<void> setSelectedFolder(String pathOrUri) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, pathOrUri);
  }

  @override
  Future<void> clearSelectedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
