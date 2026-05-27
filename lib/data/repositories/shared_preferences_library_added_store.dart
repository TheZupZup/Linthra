import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/library_added_store.dart';

/// A [LibraryAddedStore] backed by `shared_preferences`.
///
/// A small map of non-secret track ids to a first-seen epoch-millis timestamp,
/// stored as `{ "<trackId>": <epochMs>, ... }`. The same key/value weight
/// favourites and the offline-download set use.
///
/// Privacy: only ids and timestamps are written — never a uri, token, or
/// authenticated URL — and it stays on the device.
class SharedPreferencesLibraryAddedStore implements LibraryAddedStore {
  const SharedPreferencesLibraryAddedStore();

  static const String _key = 'library_added_v1';

  @override
  Future<Map<String, DateTime>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <String, DateTime>{};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // A corrupt record reads as "nothing recorded" rather than crashing.
      return <String, DateTime>{};
    }
    if (decoded is! Map<String, dynamic>) return <String, DateTime>{};
    final Map<String, DateTime> addedAt = <String, DateTime>{};
    decoded.forEach((String id, Object? value) {
      if (id.isEmpty || value is! int) return;
      addedAt[id] = DateTime.fromMillisecondsSinceEpoch(value);
    });
    return addedAt;
  }

  @override
  Future<void> save(Map<String, DateTime> addedAt) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> document = <String, dynamic>{
      for (final MapEntry<String, DateTime> entry in addedAt.entries)
        entry.key: entry.value.millisecondsSinceEpoch,
    };
    await prefs.setString(_key, jsonEncode(document));
  }
}
