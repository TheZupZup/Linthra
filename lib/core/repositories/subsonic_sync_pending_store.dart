/// Remembers that a Subsonic/Navidrome library sync started for an account and
/// has not finished yet, so the app can pick it up again after being frozen,
/// backgrounded or killed partway (issue #680).
///
/// The sync writes the account's fingerprint (see `subsonicAccountFingerprint`)
/// here before its first batch and clears it once the walk has run to its end.
/// A fingerprint still present at launch or resume therefore means "a sync for
/// this account was interrupted": the controller re-runs it, which is safe
/// because every sync step is idempotent. Kept behind this seam so the backing
/// store swaps freely (in-memory for tests, key/value in the app), mirroring
/// `SubsonicAutoSyncStore`.
///
/// Privacy: only the non-secret, one-way fingerprint is stored, never a token,
/// salt, server URL, username, or authenticated URL, and it never leaves the
/// device.
abstract interface class SubsonicSyncPendingStore {
  /// The fingerprint of the account whose sync is unfinished, or `null`.
  Future<String?> read();

  /// Records [fingerprint] as the account whose sync has started.
  Future<void> write(String fingerprint);

  /// Forgets the unfinished sync.
  Future<void> clear();
}
