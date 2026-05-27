import '../../core/repositories/library_added_store.dart';

/// A non-persistent [LibraryAddedStore] for development and tests.
class InMemoryLibraryAddedStore implements LibraryAddedStore {
  InMemoryLibraryAddedStore([Map<String, DateTime>? initial])
      : _addedAt = <String, DateTime>{...?initial};

  final Map<String, DateTime> _addedAt;

  @override
  Future<Map<String, DateTime>> load() async =>
      Map<String, DateTime>.of(_addedAt);

  @override
  Future<void> save(Map<String, DateTime> addedAt) async {
    _addedAt
      ..clear()
      ..addAll(addedAt);
  }
}
