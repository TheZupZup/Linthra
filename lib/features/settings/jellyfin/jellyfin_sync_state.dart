/// Where a Jellyfin library sync is in its lifecycle.
enum JellyfinSyncStatus { idle, syncing, success, error }

/// Immutable snapshot the Jellyfin settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], and how many tracks landed. It never
/// carries a token, password, or streaming URL.
class JellyfinSyncState {
  const JellyfinSyncState({
    this.status = JellyfinSyncStatus.idle,
    this.message,
    this.trackCount = 0,
  });

  const JellyfinSyncState.syncing()
      : this(
          status: JellyfinSyncStatus.syncing,
          message: 'Syncing your Jellyfin library…',
        );

  const JellyfinSyncState.success({
    required int trackCount,
    required String message,
  }) : this(
          status: JellyfinSyncStatus.success,
          trackCount: trackCount,
          message: message,
        );

  const JellyfinSyncState.error(String message)
      : this(status: JellyfinSyncStatus.error, message: message);

  final JellyfinSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored.
  final int trackCount;

  bool get isSyncing => status == JellyfinSyncStatus.syncing;
  bool get isError => status == JellyfinSyncStatus.error;
}
