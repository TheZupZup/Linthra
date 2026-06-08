import '../../core/repositories/playback_source_strategy_store.dart';

/// An in-memory [PlaybackSourceStrategyStore] for development and tests. Nothing
/// is persisted; the choice lives only for the lifetime of the instance.
class InMemoryPlaybackSourceStrategyStore
    implements PlaybackSourceStrategyStore {
  InMemoryPlaybackSourceStrategyStore([this._strategyName]);

  String? _strategyName;

  @override
  Future<String?> read() async => _strategyName;

  @override
  Future<void> write(String? strategyName) async {
    _strategyName = strategyName;
  }
}
