import '../models/plex_session.dart';

/// Persists the single Plex [PlexSession] across app restarts.
///
/// Deliberately separate from authentication (which *produces* a session) and
/// from library fetching (which *uses* one): this contract owns only the storage
/// of the signed-in session, so the secret, server-scoped token has exactly one
/// persistence path that can be made secure in isolation.
///
/// The production binding encrypts on-device; tests and dev use an in-memory
/// implementation. No password is ever given to this store (phase 1 pastes a
/// token directly) — only the session (token + server metadata) is.
abstract interface class PlexSessionStore {
  /// The persisted session, or `null` if the user isn't signed in (or the
  /// stored record was missing/corrupt).
  Future<PlexSession?> read();

  /// Persists [session], replacing any previous one.
  Future<void> write(PlexSession session);

  /// Forgets the signed-in session (sign out).
  Future<void> clear();
}
