/// Persists the order the Library's Songs list was last sorted in (#893), so it
/// reopens the way the user left it instead of always by title.
///
/// The stored value is a single non-secret order name (`titleAscending`,
/// `newestAdded`, …), never an index. An absent or unrecognised value reads as
/// "no choice", which the Library treats as title, A to Z.
///
/// Carries no credential, URL, or library content, so a lightweight key/value
/// store is the right weight.
abstract interface class LibrarySongSortStore {
  /// The persisted order name, or `null` when there is no stored choice.
  Future<String?> read();

  /// Persists [sortName], or clears the choice when `null`.
  Future<void> write(String? sortName);
}
