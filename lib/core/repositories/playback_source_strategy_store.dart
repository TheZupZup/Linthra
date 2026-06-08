/// Persists the user's chosen playback **source strategy** — how Linthra orders
/// the candidates of a song that exists on more than one provider.
///
/// The stored value is a single non-secret enum name (e.g. `preferLocalCache`),
/// or `null` for the default ("prefer default provider"). Like
/// [DefaultProviderStore] it carries no credential, URL, or library content, so
/// a lightweight key/value store is the right weight.
abstract interface class PlaybackSourceStrategyStore {
  /// The persisted strategy name, or `null` when the user has not chosen one
  /// (the default strategy applies).
  Future<String?> read();

  /// Persists [strategyName], or clears the choice (the default) when `null`.
  Future<void> write(String? strategyName);
}
