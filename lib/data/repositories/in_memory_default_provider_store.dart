import '../../core/repositories/default_provider_store.dart';

/// An in-memory [DefaultProviderStore] for development and tests. Nothing is
/// persisted; the choice lives only for the lifetime of the instance.
class InMemoryDefaultProviderStore implements DefaultProviderStore {
  InMemoryDefaultProviderStore([this._sourceId]);

  String? _sourceId;

  @override
  Future<String?> read() async => _sourceId;

  @override
  Future<void> write(String? sourceId) async {
    _sourceId = sourceId;
  }
}
