/// Where a Jellyfin library sync is in its lifecycle.
enum JellyfinSyncStatus { idle, syncing, success, error }

/// Immutable snapshot the Jellyfin settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], and how many tracks/playlists/
/// favourites landed. It never carries a token, password, or streaming URL.
class JellyfinSyncState {
  const JellyfinSyncState({
    this.status = JellyfinSyncStatus.idle,
    this.message,
    this.trackCount = 0,
    this.playlistCount = 0,
    this.favoriteCount = 0,
    this.playlistsFailed = false,
    this.favoritesFailed = false,
  });

  const JellyfinSyncState.syncing()
      : this(
          status: JellyfinSyncStatus.syncing,
          message: 'Syncing your Jellyfin library…',
        );

  const JellyfinSyncState.success({
    required int trackCount,
    required String message,
    int playlistCount = 0,
    int favoriteCount = 0,
    bool playlistsFailed = false,
    bool favoritesFailed = false,
  }) : this(
          status: JellyfinSyncStatus.success,
          trackCount: trackCount,
          message: message,
          playlistCount: playlistCount,
          favoriteCount: favoriteCount,
          playlistsFailed: playlistsFailed,
          favoritesFailed: favoritesFailed,
        );

  const JellyfinSyncState.error(String message)
      : this(status: JellyfinSyncStatus.error, message: message);

  final JellyfinSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored.
  final int trackCount;

  /// How many Jellyfin playlists the last successful sync imported/updated.
  final int playlistCount;

  /// How many server-synced favourites the last successful sync reconciled.
  final int favoriteCount;

  /// Whether the playlist part of the last sync failed (tracks may still have
  /// synced), so the UI can be honest about the partial outcome.
  final bool playlistsFailed;

  /// Whether the favourites part of the last sync failed.
  final bool favoritesFailed;

  bool get isSyncing => status == JellyfinSyncStatus.syncing;
  bool get isError => status == JellyfinSyncStatus.error;
}
