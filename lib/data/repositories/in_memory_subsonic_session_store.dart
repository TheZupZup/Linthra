import '../../core/models/subsonic_session.dart';
import '../../core/repositories/subsonic_session_store.dart';

/// A non-persistent [SubsonicSessionStore] for development and tests.
///
/// Holds the session in a single field, so it's forgotten when the instance is
/// dropped. This is the default binding (mirroring the other repositories); the
/// running app swaps in [SecureSubsonicSessionStore] so the credential survives
/// restarts in encrypted storage.
class InMemorySubsonicSessionStore implements SubsonicSessionStore {
  InMemorySubsonicSessionStore({SubsonicSession? initialSession})
      : _session = initialSession;

  SubsonicSession? _session;

  @override
  Future<SubsonicSession?> read() async => _session;

  @override
  Future<void> write(SubsonicSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}
