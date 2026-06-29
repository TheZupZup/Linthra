/// Where a Jellyfin library sync is in its lifecycle.
enum JellyfinSyncStatus { idle, syncing, success, error }

/// Why a Jellyfin sync failed, so the UI can offer the *right* calm next step
/// instead of one generic "error".
///
/// Branching on this (not on message text) lets the settings card show a
/// reconnect prompt for an expired session, a "try again" for a server that's
/// merely unreachable or briefly erroring, and a neutral fallback otherwise —
/// the user-facing states the sync is meant to surface.
enum JellyfinSyncFailureReason {
  /// The server couldn't be reached at all (offline, tunnel down) — confirmed by
  /// a follow-up reachability probe that *also* failed to reach it. Retrying
  /// later is the fix.
  serverUnreachable,

  /// The session/token was rejected (401/403). The fix is to sign in again, not
  /// to retry the same sync — so the UI points at reconnect, not "Retry".
  signInRequired,

  /// The connection and session are fine (a reachability probe succeeded), but
  /// the *library sync itself* didn't finish — a slow/large listing, a transient
  /// listing error, a partial response. The existing library is kept and the
  /// fix is simply to retry; crucially, this is NOT "server unreachable" and NOT
  /// "sign in again", so the UI stays calm and accurate.
  librarySyncFailed,

  /// The server answered but with a transient error (5xx) on both the sync and
  /// the reachability probe. Retrying in a moment is the fix.
  retryLater,

  /// Anything else (a non-Jellyfin response, an unusable shape, a local save
  /// hiccup): a neutral failure the user can retry.
  generic,
}

/// Immutable snapshot the Jellyfin settings UI renders the sync action from.
///
/// Like every other state object in the app, this holds only display-safe
/// values: a status, a friendly [message], how many tracks/playlists/favourites
/// landed, how many items were skipped, and — on failure — a typed
/// [failureReason]. It never carries a token, password, or streaming URL.
class JellyfinSyncState {
  const JellyfinSyncState({
    this.status = JellyfinSyncStatus.idle,
    this.message,
    this.trackCount = 0,
    this.playlistCount = 0,
    this.favoriteCount = 0,
    this.skippedCount = 0,
    this.playlistsFailed = false,
    this.favoritesFailed = false,
    this.failureReason,
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
    int skippedCount = 0,
    bool playlistsFailed = false,
    bool favoritesFailed = false,
  }) : this(
          status: JellyfinSyncStatus.success,
          trackCount: trackCount,
          message: message,
          playlistCount: playlistCount,
          favoriteCount: favoriteCount,
          skippedCount: skippedCount,
          playlistsFailed: playlistsFailed,
          favoritesFailed: favoritesFailed,
        );

  const JellyfinSyncState.error(
    String message, {
    JellyfinSyncFailureReason reason = JellyfinSyncFailureReason.generic,
  }) : this(
          status: JellyfinSyncStatus.error,
          message: message,
          failureReason: reason,
        );

  final JellyfinSyncStatus status;

  /// A friendly status or error line for the UI; never contains a secret.
  final String? message;

  /// How many tracks the last successful sync stored.
  final int trackCount;

  /// How many Jellyfin playlists the last successful sync imported/updated.
  final int playlistCount;

  /// How many server-synced favourites the last successful sync reconciled.
  final int favoriteCount;

  /// How many items the last sync skipped because they were too malformed to
  /// map. A successful sync with a non-zero count is the "synced with skipped
  /// items" outcome — usable music landed, a few entries were dropped.
  final int skippedCount;

  /// Whether the playlist part of the last sync failed (tracks may still have
  /// synced), so the UI can be honest about the partial outcome.
  final bool playlistsFailed;

  /// Whether the favourites part of the last sync failed.
  final bool favoritesFailed;

  /// Why the last sync failed, when it did — so the UI can pick the right next
  /// step. Null unless [status] is [JellyfinSyncStatus.error].
  final JellyfinSyncFailureReason? failureReason;

  bool get isSyncing => status == JellyfinSyncStatus.syncing;
  bool get isError => status == JellyfinSyncStatus.error;

  /// A success that nonetheless dropped some unparseable items — the calm
  /// "synced, but some items could not be synced" state.
  bool get syncedWithSkippedItems =>
      status == JellyfinSyncStatus.success && skippedCount > 0;

  /// The failure needs a fresh sign-in (an expired/rejected session), so the UI
  /// should prompt to reconnect rather than offer a pointless "Retry".
  bool get needsSignIn =>
      failureReason == JellyfinSyncFailureReason.signInRequired;

  /// The connection/session checked out but the library sync failed — the calm
  /// "your music is still here, try again" state. Lets the UI reassure the user
  /// the server is fine and the existing library is intact.
  bool get connectionOkButSyncFailed =>
      failureReason == JellyfinSyncFailureReason.librarySyncFailed;
}
