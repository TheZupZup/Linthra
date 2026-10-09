import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/song_origin_legacy_store.dart';

/// A [SongOriginLegacyStore] backed by `shared_preferences`: one small JSON
/// object, uri scheme → origin.
///
/// Privacy: an origin is a one-way account fingerprint or a Plex server's
/// public machine identifier, never a credential.
class SharedPreferencesSongOriginLegacyStore implements SongOriginLegacyStore {
  const SharedPreferencesSongOriginLegacyStore();

  static const String _key = 'song_origin_legacy_v1';

  @override
  Future<Map<String, String>> read() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <String, String>{};
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('song origin record is not an object');
    }
    return <String, String>{
      for (final MapEntry<Object?, Object?> entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  @override
  Future<void> write(Map<String, String> settled) async {
    bool written;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      written = await prefs.setString(_key, jsonEncode(settled));
    } catch (_) {
      written = false;
    }
    if (!written) throw StateError('song origin record was not saved');
  }
}
