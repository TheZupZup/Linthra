import 'dart:convert';

import '../../core/models/subsonic_session.dart';
import '../../core/repositories/subsonic_session_store.dart';
import 'secure_session_storage.dart';

/// A [SubsonicSessionStore] backed by `flutter_secure_storage`.
///
/// The session is serialized to JSON and written to platform secure storage
/// under a single key, through [SecureSessionStorage]: the Android
/// Keystore-backed store on Android, and libsecret on Linux (the freedesktop
/// Secret Service natively; inside a Flatpak, libsecret's own portal-keyed
/// encrypted store). The credential (salt + token, or the password of a legacy
/// sign-in) is never at rest in plaintext (unlike `shared_preferences`) on
/// either platform, and Linthra
/// writes no file of its
/// own when the platform store is unavailable. This is the production binding;
/// it's intentionally never touched by tests, which use the in-memory store so
/// they stay free of platform channels.
///
/// A malformed/partial record reads back as `null` (treated as "signed out")
/// rather than throwing, so a storage glitch can't wedge the app at launch. A
/// platform store that is missing, locked or denied is a different thing and is
/// not flattened into "signed out": [SecureSessionStorage] surfaces it as a
/// `SecureStorageException`, which the caller reports so the user can act on
/// it (unlock the keyring, sign in again) instead of losing the credential
/// silently.
class SecureSubsonicSessionStore implements SubsonicSessionStore {
  const SecureSubsonicSessionStore({
    SecureSessionStorage storage = const SecureSessionStorage(),
  }) : _storage = storage;

  final SecureSessionStorage _storage;

  static const String _key = 'subsonic_session_v1';

  @override
  Future<SubsonicSession?> read() async {
    final String? raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return SubsonicSession.fromJson(decoded);
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(SubsonicSession session) async {
    await _storage.write(key: _key, value: jsonEncode(session.toJson()));
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
  }
}
