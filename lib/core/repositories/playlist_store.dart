import '../models/playlist.dart';

/// Durable storage for the user's playlists.
///
/// The persistence seam under [PlaylistRepository]: it knows nothing about
/// Jellyfin or sync — only how to load and save the full list of [Playlist]s.
/// Splitting it out lets the backing store swap freely (in-memory for tests, a
/// key/value document in the app), mirroring how favourites and downloads are
/// persisted.
///
/// Security: only non-secret playlist metadata and stable track ids are stored
/// here — never a token or an authenticated URL.
abstract interface class PlaylistStore {
  Future<List<Playlist>> load();
  Future<void> save(List<Playlist> playlists);
}
