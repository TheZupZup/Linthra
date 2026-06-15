/// Remembers the content signature of the **last successful Plex sync**, so a
/// re-sync of an *unchanged* Plex library — after an app restart, a manual
/// "Sync" tap, or a same-server reconnect — can skip rebuilding the on-device
/// catalog and reloading the Library screen.
///
/// The signature is the same credential-free fingerprint `PlexSyncController`
/// already computes (selected sections + each track's identity/display fields,
/// folded into a one-way hash). Keeping it only in memory meant every launch
/// treated the library as "possibly changed" and rebuilt the catalog from
/// scratch on the next sync; persisting it lets the "nothing changed" fast path
/// survive a restart, which is what makes a re-sync of an unchanged library
/// cheap.
///
/// Scoped by the server's `machineIdentifier`: [readSignature] only returns a
/// signature stored for the **same** server, so reconnecting to a *different*
/// Plex server never matches a stale fingerprint (the catalog is rebuilt, as it
/// must be — another server's `ratingKey`s are different items). Kept behind
/// this seam so the backing store swaps freely (in-memory for tests, key/value
/// in the app), mirroring [JellyfinAutoSyncStore].
///
/// Privacy: the stored value is non-secret by construction — section keys, a
/// track count, and a one-way content hash, plus the (non-secret)
/// `machineIdentifier`. It carries no token, server URL, authenticated URL,
/// track title, or file path, so plain (unencrypted) key/value storage is the
/// right weight, exactly as the Jellyfin auto-sync fingerprint uses.
abstract interface class PlexSyncCacheStore {
  /// The persisted signature of the last successful sync for the server with
  /// [machineIdentifier], or `null` when none is stored (or the stored record
  /// belongs to a different server). A corrupt/absent record reads as `null`
  /// rather than throwing, so a storage hiccup only costs one extra rebuild.
  Future<String?> readSignature(String machineIdentifier);

  /// Records [signature] as the last successful sync for the server with
  /// [machineIdentifier], replacing any previous record (for this or another
  /// server).
  Future<void> writeSignature(String machineIdentifier, String signature);

  /// Forgets the recorded signature (e.g. on disconnect, or when connecting to a
  /// different server cleared the Plex catalog slice). Never throws.
  Future<void> clear();
}
