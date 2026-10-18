import '../../core/repositories/library_song_sort_store.dart';

/// An in-memory [LibrarySongSortStore] for development and tests. Nothing is
/// persisted; the choice lives only for the lifetime of the instance.
class InMemoryLibrarySongSortStore implements LibrarySongSortStore {
  InMemoryLibrarySongSortStore([this._sortName]);

  String? _sortName;

  @override
  Future<String?> read() async => _sortName;

  @override
  Future<void> write(String? sortName) async {
    _sortName = sortName;
  }
}
