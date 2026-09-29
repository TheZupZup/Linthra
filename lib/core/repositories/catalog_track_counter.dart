/// Optional capability a [MusicLibraryRepository] may also implement to count
/// its rows without loading them.
///
/// Diagnostics only needs "how many tracks are stored"; answering that with
/// `getAllTracks().length` materializes every row, which on a large library
/// (tens of thousands of tracks) is a lot of work for one number. A caller
/// checks `repo is CatalogTrackCounter` and falls back otherwise.
abstract interface class CatalogTrackCounter {
  /// How many tracks are stored, across every source, or only [sourceId]'s
  /// slice when it is given.
  Future<int> countTracks({String? sourceId});
}
