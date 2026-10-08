import '../../core/repositories/pending_track_move_store.dart';

/// A non-persistent [PendingTrackMoveStore] for development and tests.
class InMemoryPendingTrackMoveStore implements PendingTrackMoveStore {
  List<PendingTrackMove> _moves = const <PendingTrackMove>[];

  @override
  Future<List<PendingTrackMove>> load() async =>
      List<PendingTrackMove>.of(_moves);

  @override
  Future<void> save(List<PendingTrackMove> moves) async {
    _moves = List<PendingTrackMove>.unmodifiable(moves);
  }

  /// Nothing here is ever unreadable, so there is never anything to set aside.
  @override
  Future<bool> setAside() async => false;
}
