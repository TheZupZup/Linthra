/// Where a Subsonic/Navidrome library sync is in its lifecycle.
///
/// [incomplete] is a sync that read to the end but could not prove it saw the
/// whole library (the album list hit its safety cap, or too many albums went
/// missing mid-walk): everything it read is saved, and nothing was pruned.
enum SubsonicSyncStatus { idle, syncing, success, incomplete, error }

/// Immutable snapshot the Subsonic settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], a stable [errorKind] name, and how
/// much came across. It never carries a token, salt, password, or streaming URL.
class SubsonicSyncState {
  const SubsonicSyncState({
    this.status = SubsonicSyncStatus.idle,
    this.message,
    this.trackCount = 0,
    this.savedTrackCount = 0,
    this.playlistCount = 0,
    this.favoriteCount = 0,
    this.playlistsFailed = false,
    this.favoritesFailed = false,
    this.errorKind,
  });

  const SubsonicSyncState.syncing({int savedTrackCount = 0})
      : this(
          status: SubsonicSyncStatus.syncing,
          message: 'Syncing your library…',
          savedTrackCount: savedTrackCount,
        );

  /// A sync that read to the end. [complete] false marks it
  /// [SubsonicSyncStatus.incomplete] (see the enum).
  const SubsonicSyncState.success({
    required int trackCount,
    required String message,
    bool complete = true,
    int playlistCount = 0,
    int favoriteCount = 0,
    bool playlistsFailed = false,
    bool favoritesFailed = false,
  }) : this(
          status: complete
              ? SubsonicSyncStatus.success
              : SubsonicSyncStatus.incomplete,
          trackCount: trackCount,
          savedTrackCount: trackCount,
          message: message,
          playlistCount: playlistCount,
          favoriteCount: favoriteCount,
          playlistsFailed: playlistsFailed,
          favoritesFailed: favoritesFailed,
        );

  const SubsonicSyncState.error(
    String message, {
    String? errorKind,
    int savedTrackCount = 0,
  }) : this(
          status: SubsonicSyncStatus.error,
          message: message,
          errorKind: errorKind,
          savedTrackCount: savedTrackCount,
        );

  final SubsonicSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored.
  final int trackCount;

  /// How many tracks this run has written to the catalog so far. Kept on an
  /// error too: an interrupted sync keeps what it already saved.
  final int savedTrackCount;

  /// How many playlists the server reported on the last successful sync.
  final int playlistCount;

  /// How many server favourites were mirrored on the last successful sync.
  final int favoriteCount;

  /// Whether the playlist refresh failed while the catalog itself synced.
  final bool playlistsFailed;

  /// Whether the favourites refresh failed while the catalog itself synced.
  final bool favoritesFailed;

  /// For [SubsonicSyncStatus.error]: a stable, secret-free name for what went
  /// wrong (a `SubsonicErrorKind` name, or [unexpectedErrorKind]), for the
  /// diagnostics report.
  final String? errorKind;

  /// The [errorKind] of a failure that wasn't a Subsonic error (a storage
  /// failure while saving, most likely).
  static const String unexpectedErrorKind = 'syncFailed';

  bool get isSyncing => status == SubsonicSyncStatus.syncing;
  bool get isError => status == SubsonicSyncStatus.error;

  /// The value of the diagnostics report's "Subsonic sync" line, or null when
  /// there is nothing to say (no sync this session and none left unfinished).
  ///
  /// [pendingRetry] is whether an unfinished sync for the current account is on
  /// record (see `SubsonicSyncPendingStore`). With the in-memory state still
  /// idle, that is the one trace a sync interrupted by the process being killed
  /// leaves behind.
  String? diagnosticsLabel({required bool pendingRetry}) {
    final String retry = pendingRetry ? ', will retry' : '';
    switch (status) {
      case SubsonicSyncStatus.idle:
        return pendingRetry ? 'interrupted, will retry' : null;
      case SubsonicSyncStatus.syncing:
        return 'syncing ($savedTrackCount saved)';
      case SubsonicSyncStatus.success:
        return 'ok ($trackCount tracks)';
      case SubsonicSyncStatus.incomplete:
        return 'incomplete ($trackCount tracks, stale tracks kept)';
      case SubsonicSyncStatus.error:
        return 'failed: ${errorKind ?? unexpectedErrorKind} '
            '($savedTrackCount saved$retry)';
    }
  }
}
