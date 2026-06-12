import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/plex_session_store.dart';
import 'in_memory_plex_session_store.dart';
import 'secure_plex_session_store.dart';

/// The single [PlexSessionStore] the app reads/writes the Plex session
/// through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins (no `flutter_secure_storage`). The running app overrides
/// this with [securePlexSessionStoreOverride] so the server-scoped token
/// persists, at rest, in encrypted storage.
final plexSessionStoreProvider = Provider<PlexSessionStore>((ref) {
  return InMemoryPlexSessionStore();
});

/// Production binding: persists the session token in encrypted on-device
/// storage. Applied in `main`.
final securePlexSessionStoreOverride =
    plexSessionStoreProvider.overrideWithValue(
  const SecurePlexSessionStore(),
);
