import 'dart:async';

import '../../core/models/play_history.dart';
import '../../core/models/track.dart';
import '../../core/repositories/play_history_repository.dart';
import '../../core/repositories/play_history_store.dart';

/// The app's [PlayHistoryRepository]: an in-memory mirror persisted through a
/// [PlayHistoryStore].
///
/// Loads the stored history lazily on first read, records a completed play by
/// bumping that track's count and last-played time, then emits and persists.
/// Mirrors `JellyfinSyncedFavoritesRepository`'s shape (load-once, emit,
/// persist) minus any server sync — play history is on-device only.
///
/// Privacy: [recordCompletion] reads only [Track.id]; no uri, token, or
/// authenticated URL is ever recorded, and nothing is sent off the device.
class DefaultPlayHistoryRepository implements PlayHistoryRepository {
  DefaultPlayHistoryRepository({
    required PlayHistoryStore store,
    DateTime Function()? now,
  })  : _store = store,
        _now = now ?? DateTime.now;

  final PlayHistoryStore _store;
  final DateTime Function() _now;

  final StreamController<PlayHistory> _changes =
      StreamController<PlayHistory>.broadcast();

  PlayHistory _history = PlayHistory.empty;
  bool _loaded = false;

  // Serialises writes so two quick completions can't race on load-then-save and
  // lose a count: each recorded play runs only after the previous one persists.
  Future<void> _writes = Future<void>.value();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _history = await _store.load();
    _loaded = true;
  }

  @override
  PlayHistory get current => _history;

  @override
  Stream<PlayHistory> get historyStream async* {
    await _ensureLoaded();
    yield _history;
    yield* _changes.stream;
  }

  @override
  Future<void> recordCompletion(Track track) {
    // Capture only the id (never the uri) and chain onto the write queue.
    final String trackId = track.id;
    _writes = _writes.then((_) async {
      try {
        await _ensureLoaded();
        _history = _history.recordPlay(trackId, _now());
        if (!_changes.isClosed) _changes.add(_history);
        await _store.save(_history);
      } catch (_) {
        // Never throw out of recordCompletion: a failed persist keeps the
        // in-memory count and the next write retries the save.
      }
    });
    return _writes;
  }

  Future<void> dispose() => _changes.close();
}
