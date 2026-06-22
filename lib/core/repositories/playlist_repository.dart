import '../models/playlist.dart';
import 'remote_sync_result.dart';

/// Persistence + editing contract for user-created playlists.
///
/// Kept separate from [MusicLibraryRepository] because playlists are
/// user-authored and mutable, whereas the catalog is derived from sources and
/// rebuilt on sync. Different lifecycles, different contracts.
///
/// The UI reads from [playlistsStream] / [getAllPlaylists] and edits through the
/// explicit operations below, never touching the backing store (or Jellyfin)
/// directly — mirroring how the player reads a `PlaybackState` and never the
/// audio engine. Editing operations persist locally first; an implementation may
/// additionally mirror the change to a server best-effort (see
/// [refreshFromRemote]), but a server failure never throws out of these methods.
abstract interface class PlaylistRepository {
  /// Emits the current playlists immediately, then on every change.
  Stream<List<Playlist>> get playlistsStream;

  Future<List<Playlist>> getAllPlaylists();
  Future<Playlist?> getPlaylistById(String id);

  /// Creates a playlist and returns it. A [source] of [PlaylistSource.jellyfin]
  /// marks it for server sync; the implementation attempts the remote create
  /// best-effort and records the resulting [Playlist.syncState].
  Future<Playlist> createPlaylist(
    String name, {
    String? description,
    PlaylistSource source = PlaylistSource.local,
  });

  /// Renames (and optionally re-describes) the playlist with [id]. Pass a
  /// [description] of `null` to leave the description unchanged.
  Future<void> renamePlaylist(String id, String name, {String? description});

  Future<void> deletePlaylist(String id);

  /// Appends [trackUri] (a provider-namespaced [Track.uri]) to the playlist if it
  /// is not already present (a no-op for a duplicate, so adding the same track
  /// twice can't create a double entry). Identity is the uri, so the same
  /// server-side id from another provider is a distinct entry, not a duplicate.
  Future<void> addTrack(String playlistId, String trackUri);

  /// Appends every uri in [trackUris] not already present, preserving their
  /// order. Entries are provider-namespaced [Track.uri]s.
  Future<void> addTracks(String playlistId, List<String> trackUris);

  /// Removes the entry for [trackUri] (a provider-namespaced [Track.uri]).
  Future<void> removeTrack(String playlistId, String trackUri);

  /// Moves the track at [oldIndex] to [newIndex] within the playlist.
  Future<void> reorderTracks(String playlistId, int oldIndex, int newIndex);

  /// Records the [state] (and optional friendly, secret-free [error]) for the
  /// playlist with [id], so the UI can show an honest sync status.
  Future<void> markSyncState(
    String id,
    PlaylistSyncState state, {
    String? error,
  });

  /// Pulls playlists from the signed-in server and reconciles them into the
  /// local set: importing new ones, adopting server name/membership for synced
  /// ones, and dropping a synced playlist whose server copy is gone (server is
  /// the source of truth for synced playlists). Local-only playlists are never
  /// touched. Never throws: it returns a [PlaylistSyncResult] describing the
  /// outcome (not configured / synced + count / failed) so the "Sync library"
  /// action can report "synced N playlists" or "playlists could not be loaded".
  Future<PlaylistSyncResult> refreshFromRemote();

  /// Drops the server-synced (remote-source) playlists, keeping local-only ones.
  /// Called on sign-out so one account's imported playlists can't linger — or be
  /// confused with a different account's — after disconnecting. A no-op when
  /// there are none. Never throws.
  Future<void> clearRemote();
}
