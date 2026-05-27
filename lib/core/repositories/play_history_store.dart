import '../models/play_history.dart';

/// Durable storage for the user's on-device [PlayHistory].
///
/// The persistence seam under [PlayHistoryRepository]: it knows nothing about
/// playback — only how to load and save the play-count/last-played map.
/// Splitting it out lets the backing store swap freely (in-memory for tests,
/// key/value in the app), mirroring [FavoritesStore].
///
/// Privacy: only non-secret track ids, play counts, and timestamps are stored
/// here — never a uri, token, or authenticated URL. Play history never leaves
/// the device.
abstract interface class PlayHistoryStore {
  Future<PlayHistory> load();
  Future<void> save(PlayHistory history);
}
