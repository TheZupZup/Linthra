/// Remembers whose library a remote source's catalog slice holds (#741).
///
/// Signing out of Jellyfin or Subsonic keeps the source's rows, so the library
/// stays visible offline. They are still the rows of the account that synced
/// them, so before anything is written for an account, its sync controller
/// compares that account with the owner recorded here and removes another
/// account's rows first. Without it, signing in to a server whose first sync
/// wrote nothing (an empty library, a failed or stopped sync) left the
/// previous account's tracks in the library under the new one.
///
/// One opaque account fingerprint per source id (`jellyfin`, `subsonic`), the
/// same one-way value the auto-sync stores keep. Kept behind this seam so the
/// backing store swaps freely (in-memory for tests, key/value in the app).
///
/// Privacy: only the non-secret fingerprint is stored, never a token, server
/// URL, user id or authenticated URL, and it never leaves the device.
abstract interface class RemoteCatalogOwnerStore {
  /// The fingerprint of the account whose rows the [sourceId] slice holds, or
  /// `null` when none was recorded.
  Future<String?> read(String sourceId);

  /// Records [fingerprint] as the account the [sourceId] slice belongs to.
  Future<void> write(String sourceId, String fingerprint);

  /// Forgets the owner of the [sourceId] slice.
  Future<void> clear(String sourceId);
}
