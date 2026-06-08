/// Persists the user's *explicit* default playback provider — the source they
/// chose to prefer when the same song exists on more than one provider.
///
/// The stored value is a single non-secret source id (`jellyfin`, `subsonic`,
/// or `local`), or `null` for **Automatic** — no explicit choice, so the
/// library keeps its most-recently-signed-in behaviour. It carries no
/// credential, URL, or library content, so a lightweight key/value store is the
/// right weight — the same reasoning [PreferredSourceStore] follows.
abstract interface class DefaultProviderStore {
  /// The persisted explicit default source id, or `null` when the user has not
  /// chosen one (Automatic).
  Future<String?> read();

  /// Persists [sourceId] (a source id), or clears the choice (Automatic) when
  /// `null`.
  Future<void> write(String? sourceId);
}
