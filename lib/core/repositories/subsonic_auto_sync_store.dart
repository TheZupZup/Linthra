/// Remembers which Subsonic/Navidrome server/account has already had its
/// **first** (automatic) library sync, so onboarding can sync once on a fresh
/// connection without re-pulling the whole library every time the same account
/// reconnects.
///
/// It stores a single opaque [String] fingerprint (see
/// `subsonicAccountFingerprint`) — the account whose initial auto-sync has
/// completed — or `null` when no account has been auto-synced yet. Kept behind
/// this seam so the backing store swaps freely (in-memory for tests, key/value
/// in the app), mirroring `JellyfinAutoSyncStore`.
///
/// Privacy: only the non-secret, one-way fingerprint is stored — never a token,
/// salt, server URL, username, or authenticated URL — and it never leaves the
/// device.
abstract interface class SubsonicAutoSyncStore {
  /// The fingerprint of the account whose initial auto-sync has completed, or
  /// `null` if none has yet.
  Future<String?> read();

  /// Records [fingerprint] as the account whose initial auto-sync has completed.
  Future<void> write(String fingerprint);

  /// Forgets the recorded fingerprint (e.g. on a hard reset). Never throws.
  Future<void> clear();
}
