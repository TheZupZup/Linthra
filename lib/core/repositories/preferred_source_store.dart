/// Persists the user's preferred provider order — the "active/default first"
/// signal the library uses to pick which copy of a duplicated song to play.
///
/// The stored value is a small ordered list of non-secret source ids
/// (`subsonic`, `jellyfin`, `local`), most-preferred first. It carries no
/// credential, URL, or library content, so a lightweight key/value store is the
/// right weight — the same reasoning the selected-folder and download stores
/// follow.
abstract interface class PreferredSourceStore {
  /// The persisted order, most-preferred first. Empty when nothing is stored yet
  /// (the library then falls back to its deterministic default order).
  Future<List<String>> read();

  /// Persists [order] verbatim (most-preferred first).
  Future<void> write(List<String> order);
}
