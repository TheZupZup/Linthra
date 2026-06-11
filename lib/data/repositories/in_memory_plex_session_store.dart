import '../../core/models/plex_session.dart';
import '../../core/repositories/plex_session_store.dart';

/// A non-persistent [PlexSessionStore] for development and tests.
///
/// Holds the session in a single field, so it's forgotten when the instance is
/// dropped. This is the default binding (mirroring the other repositories); the
/// running app swaps in [SecurePlexSessionStore] so the server-scoped token
/// survives restarts in encrypted storage.
class InMemoryPlexSessionStore implements PlexSessionStore {
  InMemoryPlexSessionStore({PlexSession? initialSession})
      : _session = initialSession;

  PlexSession? _session;

  @override
  Future<PlexSession?> read() async => _session;

  @override
  Future<void> write(PlexSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}
