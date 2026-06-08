import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/preferred_source_store.dart';

/// A [PreferredSourceStore] backed by `shared_preferences`.
///
/// The preferred provider order is a tiny list of non-secret source ids, so a
/// single JSON string under one key is plenty — no token, URL, or library
/// content is ever written here. A corrupt or absent value reads as "no
/// preference yet" rather than throwing, so a storage hiccup can never break
/// library loading or playback.
class SharedPreferencesPreferredSourceStore implements PreferredSourceStore {
  SharedPreferencesPreferredSourceStore();

  static const String _key = 'preferred_source_order_v1';

  @override
  Future<List<String>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const <String>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <String>[];
    }
    if (decoded is! List) return const <String>[];
    return <String>[
      for (final Object? id in decoded)
        if (id is String && id.isNotEmpty) id,
    ];
  }

  @override
  Future<void> write(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(order));
  }
}
