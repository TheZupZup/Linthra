import '../../core/models/jellyfin_session.dart';
import '../../core/repositories/jellyfin_session_store.dart';

/// A non-persistent [JellyfinSessionStore] for development and tests.
///
/// Holds the session in a single field, so it's forgotten when the instance is
/// dropped. This is the default binding (mirroring the other repositories); the
/// running app swaps in [SecureJellyfinSessionStore] so the token survives
/// restarts in encrypted storage.
class InMemoryJellyfinSessionStore implements JellyfinSessionStore {
  InMemoryJellyfinSessionStore({JellyfinSession? initialSession})
      : _session = initialSession;

  JellyfinSession? _session;

  @override
  Future<JellyfinSession?> read() async => _session;

  @override
  Future<void> write(JellyfinSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}
