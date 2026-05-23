import '../../core/repositories/download_store.dart';

/// A non-persistent [DownloadStore] for development and tests.
///
/// Keeps the cached IDs in a plain set, so they're forgotten when the instance
/// is dropped. Default binding (mirroring the other in-memory repositories);
/// the running app swaps in the `shared_preferences` implementation.
class InMemoryDownloadStore implements DownloadStore {
  InMemoryDownloadStore({Set<String>? initialIds})
      : _ids = <String>{...?initialIds};

  final Set<String> _ids;

  @override
  Future<Set<String>> loadDownloadedIds() async => <String>{..._ids};

  @override
  Future<void> saveDownloadedIds(Set<String> ids) async {
    _ids
      ..clear()
      ..addAll(ids);
  }
}
