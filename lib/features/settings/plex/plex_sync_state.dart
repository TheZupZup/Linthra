/// Where a Plex library sync is in its lifecycle.
enum PlexSyncStatus { idle, syncing, success, error }

/// Immutable snapshot the Plex settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], and how many tracks landed. It
/// never carries the Plex token or a tokenized stream/art URL — every message
/// is static or built from a token-free `PlexException`.
class PlexSyncState {
  const PlexSyncState({
    this.status = PlexSyncStatus.idle,
    this.message,
    this.trackCount = 0,
  });

  const PlexSyncState.syncing()
      : this(
          status: PlexSyncStatus.syncing,
          message: 'Syncing your Plex libraries…',
        );

  const PlexSyncState.success({
    required int trackCount,
    required String message,
  }) : this(
          status: PlexSyncStatus.success,
          trackCount: trackCount,
          message: message,
        );

  const PlexSyncState.error(String message)
      : this(status: PlexSyncStatus.error, message: message);

  final PlexSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored.
  final int trackCount;

  bool get isSyncing => status == PlexSyncStatus.syncing;
  bool get isError => status == PlexSyncStatus.error;
}
