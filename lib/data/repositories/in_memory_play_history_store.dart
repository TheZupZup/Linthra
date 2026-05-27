import '../../core/models/play_history.dart';
import '../../core/repositories/play_history_store.dart';

/// A non-persistent [PlayHistoryStore] for development and tests.
class InMemoryPlayHistoryStore implements PlayHistoryStore {
  InMemoryPlayHistoryStore([PlayHistory initial = PlayHistory.empty])
      : _history = initial;

  PlayHistory _history;

  @override
  Future<PlayHistory> load() async => _history;

  @override
  Future<void> save(PlayHistory history) async {
    _history = history;
  }
}
