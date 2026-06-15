import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/plex_sync_cache_store.dart';

/// A [PlexSyncCacheStore] backed by `shared_preferences`.
///
/// Persists a tiny JSON record — `{ machineIdentifier, signature }` — under one
/// key. The server's `machineIdentifier` is stored alongside the signature so
/// [readSignature] can refuse a fingerprint that belongs to a *different* Plex
/// server (reconnecting elsewhere must rebuild the catalog, not skip it).
///
/// Privacy: both fields are non-secret — the `machineIdentifier` is the server's
/// public id, and the signature is a one-way content hash over section keys +
/// track count + per-track display fields (never a token, URL, title, or path).
/// Plain `shared_preferences` (not encrypted storage) is the right weight here
/// precisely because there is no secret, exactly like the Jellyfin auto-sync
/// fingerprint. A corrupt or absent value reads as "no record" rather than
/// throwing, so a storage hiccup can never break a sync — at worst it costs one
/// redundant rebuild.
class SharedPreferencesPlexSyncCacheStore implements PlexSyncCacheStore {
  const SharedPreferencesPlexSyncCacheStore();

  static const String _key = 'plex_sync_cache_v1';
  static const String _machineField = 'machineIdentifier';
  static const String _signatureField = 'signature';

  @override
  Future<String?> readSignature(String machineIdentifier) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    // Only return a signature stored for this exact server; a record from a
    // different machine must not match (its catalog rows are different items).
    if (decoded[_machineField] != machineIdentifier) return null;
    final Object? signature = decoded[_signatureField];
    return signature is String && signature.isNotEmpty ? signature : null;
  }

  @override
  Future<void> writeSignature(
    String machineIdentifier,
    String signature,
  ) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(<String, String>{
        _machineField: machineIdentifier,
        _signatureField: signature,
      }),
    );
  }

  @override
  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
