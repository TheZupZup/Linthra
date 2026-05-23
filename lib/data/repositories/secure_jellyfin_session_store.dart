import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/models/jellyfin_session.dart';
import '../../core/repositories/jellyfin_session_store.dart';

/// A [JellyfinSessionStore] backed by `flutter_secure_storage`.
///
/// The session is serialized to JSON and written to platform-encrypted storage
/// (Android Keystore-backed) under a single key, so the access token is never
/// at rest in plaintext (unlike `shared_preferences`). This is the production
/// binding; it's intentionally never touched by tests, which use the in-memory
/// store so they stay free of platform channels.
///
/// A malformed/partial record reads back as `null` (treated as "signed out")
/// rather than throwing, so a storage glitch can't wedge the app at launch.
class SecureJellyfinSessionStore implements JellyfinSessionStore {
  const SecureJellyfinSessionStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  static const String _key = 'jellyfin_session_v1';

  @override
  Future<JellyfinSession?> read() async {
    final String? raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return JellyfinSession.fromJson(decoded);
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(JellyfinSession session) async {
    await _storage.write(key: _key, value: jsonEncode(session.toJson()));
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
  }
}
