import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/jellyfin_session_store.dart';
import 'in_memory_jellyfin_session_store.dart';
import 'secure_jellyfin_session_store.dart';

/// The single [JellyfinSessionStore] the app reads/writes the Jellyfin session
/// through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins (no `flutter_secure_storage`). The running app overrides
/// this with [secureJellyfinSessionStoreOverride] so the token persists, at
/// rest, in encrypted storage.
final jellyfinSessionStoreProvider = Provider<JellyfinSessionStore>((ref) {
  return InMemoryJellyfinSessionStore();
});

/// Production binding: persists the session token in encrypted on-device
/// storage. Applied in `main`.
final secureJellyfinSessionStoreOverride =
    jellyfinSessionStoreProvider.overrideWithValue(
  const SecureJellyfinSessionStore(),
);
