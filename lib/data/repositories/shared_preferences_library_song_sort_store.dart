import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/library_song_sort_store.dart';

/// A [LibrarySongSortStore] backed by `shared_preferences`.
///
/// One non-secret string under one key. An absent or empty value reads as
/// `null` (title, A to Z) rather than throwing, so a storage problem degrades
/// to the order the list always had instead of breaking the Library screen.
class SharedPreferencesLibrarySongSortStore implements LibrarySongSortStore {
  const SharedPreferencesLibrarySongSortStore();

  static const String _key = 'library_song_sort_v1';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> write(String? sortName) async {
    final prefs = await SharedPreferences.getInstance();
    if (sortName == null || sortName.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, sortName);
  }
}
