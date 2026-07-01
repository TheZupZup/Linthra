/// Where a Subsonic/Navidrome library sync is in its lifecycle.
enum SubsonicSyncStatus { idle, syncing, success, error }

/// Immutable snapshot the Subsonic settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], and how much came across. It never
/// carries a token, salt, password, or streaming URL.
class SubsonicSyncState {
  const SubsonicSyncState({
    this.status = SubsonicSyncStatus.idle,
    this.message,
    this.trackCount = 0,
    this.playlistCount = 0,
    this.favoriteCount = 0,
    this.playlistsFailed = false,
    this.favoritesFailed = false,
  });

  const SubsonicSyncState.syncing()
      : this(
          status: SubsonicSyncStatus.syncing,
          message: 'Syncing your library…',
        );

  const SubsonicSyncState.success({
    required int trackCount,
    required String message,
    int playlistCount = 0,
    int favoriteCount = 0,
    bool playlistsFailed = false,
    bool favoritesFailed = false,
  }) : this(
          status: SubsonicSyncStatus.success,
          trackCount: trackCount,
          message: message,
          playlistCount: playlistCount,
          favoriteCount: favoriteCount,
          playlistsFailed: playlistsFailed,
          favoritesFailed: favoritesFailed,
        );

  const SubsonicSyncState.error(String message)
      : this(status: SubsonicSyncStatus.error, message: message);

  final SubsonicSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored.
  final int trackCount;

  /// How many playlists the server reported on the last successful sync.
  final int playlistCount;

  /// How many server favourites were mirrored on the last successful sync.
  final int favoriteCount;

  /// Whether the playlist refresh failed while the catalog itself synced.
  final bool playlistsFailed;

  /// Whether the favourites refresh failed while the catalog itself synced.
  final bool favoritesFailed;

  bool get isSyncing => status == SubsonicSyncStatus.syncing;
  bool get isError => status == SubsonicSyncStatus.error;
}
