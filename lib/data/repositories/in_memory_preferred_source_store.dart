import '../../core/repositories/preferred_source_store.dart';

/// An in-memory [PreferredSourceStore] for development and tests. Nothing is
/// persisted; the order lives only for the lifetime of the instance.
class InMemoryPreferredSourceStore implements PreferredSourceStore {
  InMemoryPreferredSourceStore([List<String> initial = const <String>[]])
      : _order = List<String>.of(initial);

  List<String> _order;

  @override
  Future<List<String>> read() async => List<String>.of(_order);

  @override
  Future<void> write(List<String> order) async {
    _order = List<String>.of(order);
  }
}
