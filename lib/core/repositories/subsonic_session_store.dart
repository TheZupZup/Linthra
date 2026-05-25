import '../models/subsonic_session.dart';

/// Persists the single Subsonic/Navidrome [SubsonicSession] across app restarts.
///
/// Deliberately separate from authentication (which *produces* a session) and
/// from library fetching (which *uses* one): this contract owns only the storage
/// of the signed-in session, so the credential (salt + token) has exactly one
/// persistence path that can be made secure in isolation.
///
/// The production binding encrypts on-device; tests and dev use an in-memory
/// implementation. The user's password is never given to this store — only the
/// session (derived salt + token + server + user) is.
abstract interface class SubsonicSessionStore {
  /// The persisted session, or `null` if the user isn't signed in (or the
  /// stored record was missing/corrupt).
  Future<SubsonicSession?> read();

  /// Persists [session], replacing any previous one.
  Future<void> write(SubsonicSession session);

  /// Forgets the signed-in session (sign out).
  Future<void> clear();
}
