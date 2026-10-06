import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/local_tag_revision_store.dart';

/// A [LocalTagRevisionStore] backed by `shared_preferences`, stored as
/// `{ "<folder>": <revision>, ... }`.
class SharedPreferencesLocalTagRevisionStore implements LocalTagRevisionStore {
  const SharedPreferencesLocalTagRevisionStore();

  static const String _key = 'local_tag_revisions_v1';

  @override
  Future<Map<String, int>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <String, int>{};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // A corrupt record reads as "nothing recorded": every folder is read in
      // full once more, which is what a scan did before this existed.
      return <String, int>{};
    }
    if (decoded is! Map<String, dynamic>) return <String, int>{};
    return <String, int>{
      for (final MapEntry<String, dynamic> entry in decoded.entries)
        if (entry.key.isNotEmpty && entry.value is int)
          entry.key: entry.value as int,
    };
  }

  @override
  Future<void> save(Map<String, int> revisions) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(revisions));
  }
}
