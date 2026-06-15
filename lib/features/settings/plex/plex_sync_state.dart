/// Where a Plex library sync is in its lifecycle.
///
/// Split into two active phases so the UI can say which is happening:
///  - [scanning] — reading the catalog from the Plex server (the network walk
///    plus the off-isolate decode);
///  - [syncing] — writing the scanned tracks into the local database, batch by
///    batch, so the library fills progressively.
///
/// [done] is the resting "finished successfully" state (a completed sync or a
/// no-op when nothing changed); [idle] is the never-run-yet state.
enum PlexSyncStatus { idle, scanning, syncing, done, error }

/// Immutable snapshot the Plex settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], and how many tracks the library
/// holds. It never carries the Plex token or a tokenized stream/art URL — every
/// message is static or built from a token-free `PlexException`.
class PlexSyncState {
  const PlexSyncState({
    this.status = PlexSyncStatus.idle,
    this.message,
    this.trackCount = 0,
  });

  /// Reading the library from the server (and decoding it off the UI isolate).
  const PlexSyncState.scanning()
      : this(
          status: PlexSyncStatus.scanning,
          message: 'Scanning your Plex libraries…',
        );

  /// Writing the scanned tracks into the local database. [trackCount] is the
  /// total being written, so the UI can show progress if it wants to.
  const PlexSyncState.syncing({int trackCount = 0})
      : this(
          status: PlexSyncStatus.syncing,
          trackCount: trackCount,
          message: 'Saving your Plex libraries…',
        );

  /// Finished successfully — a completed sync or an up-to-date no-op.
  const PlexSyncState.done({
    required int trackCount,
    required String message,
  }) : this(
          status: PlexSyncStatus.done,
          trackCount: trackCount,
          message: message,
        );

  const PlexSyncState.error(String message)
      : this(status: PlexSyncStatus.error, message: message);

  final PlexSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored (or is storing).
  final int trackCount;

  /// Reading from the server.
  bool get isScanning => status == PlexSyncStatus.scanning;

  /// Writing to the local database.
  bool get isWriting => status == PlexSyncStatus.syncing;

  /// Any active phase — scanning **or** writing. Kept named `isSyncing` because
  /// the UI uses it as the single "a sync is in progress" flag (spinner shown,
  /// actions disabled) across both phases.
  bool get isSyncing => isScanning || isWriting;

  bool get isError => status == PlexSyncStatus.error;
  bool get isDone => status == PlexSyncStatus.done;
}
