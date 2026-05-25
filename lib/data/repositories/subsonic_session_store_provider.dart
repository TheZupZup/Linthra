import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/subsonic_session_store.dart';
import 'in_memory_subsonic_session_store.dart';
import 'secure_subsonic_session_store.dart';

/// The single [SubsonicSessionStore] the app reads/writes the Subsonic session
/// through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins (no `flutter_secure_storage`). The running app overrides
/// this with [secureSubsonicSessionStoreOverride] so the credential persists, at
/// rest, in encrypted storage.
final subsonicSessionStoreProvider = Provider<SubsonicSessionStore>((ref) {
  return InMemorySubsonicSessionStore();
});

/// Production binding: persists the session credential in encrypted on-device
/// storage. Applied in `main`.
final secureSubsonicSessionStoreOverride =
    subsonicSessionStoreProvider.overrideWithValue(
  const SecureSubsonicSessionStore(),
);
