/// Where a Subsonic/Navidrome library sync is in its lifecycle.
enum SubsonicSyncStatus { idle, syncing, success, error }

/// Immutable snapshot the Subsonic settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], and how many tracks landed. It never
/// carries a token, salt, password, or streaming URL.
class SubsonicSyncState {
  const SubsonicSyncState({
    this.status = SubsonicSyncStatus.idle,
    this.message,
    this.trackCount = 0,
  });

  const SubsonicSyncState.syncing()
      : this(
          status: SubsonicSyncStatus.syncing,
          message: 'Syncing your library…',
        );

  const SubsonicSyncState.success({
    required int trackCount,
    required String message,
  }) : this(
          status: SubsonicSyncStatus.success,
          trackCount: trackCount,
          message: message,
        );

  const SubsonicSyncState.error(String message)
      : this(status: SubsonicSyncStatus.error, message: message);

  final SubsonicSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored.
  final int trackCount;

  bool get isSyncing => status == SubsonicSyncStatus.syncing;
  bool get isError => status == SubsonicSyncStatus.error;
}
