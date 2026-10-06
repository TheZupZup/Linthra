import '../../core/repositories/local_tag_revision_store.dart';

/// A non-persistent [LocalTagRevisionStore] for development and tests.
class InMemoryLocalTagRevisionStore implements LocalTagRevisionStore {
  InMemoryLocalTagRevisionStore([Map<String, int>? initial])
      : _revisions = <String, int>{...?initial};

  final Map<String, int> _revisions;

  @override
  Future<Map<String, int>> load() async => Map<String, int>.of(_revisions);

  @override
  Future<void> save(Map<String, int> revisions) async {
    _revisions
      ..clear()
      ..addAll(revisions);
  }
}
