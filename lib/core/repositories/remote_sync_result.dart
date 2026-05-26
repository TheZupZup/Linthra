import 'package:flutter/foundation.dart';

/// The outcome of pulling account-specific state (favourites or playlists) from
/// a remote server during a sync.
///
/// Distinguishes "there was nothing to sync" (no client / no signed-in session —
/// a local-only or signed-out setup) from a genuine failure, so the sync UI can
/// stay quiet when there's no server yet report an honest "couldn't load" when a
/// signed-in refresh fails. Carrying this — rather than a bare bool or a thrown
/// error — keeps `refreshFromRemote` non-throwing while still letting the caller
/// report "synced N playlists" or "favorites could not be synced".
enum RemoteSyncOutcome {
  /// No remote is configured (no client or no signed-in session): nothing was
  /// attempted, so there is nothing to report.
  notConfigured,

  /// The refresh reached the server and reconciled local state successfully.
  synced,

  /// A refresh was attempted but the server (or transport) failed.
  failed,
}

/// Result of `FavoritesRepository.refreshFromRemote`. Display-safe: it carries
/// only an outcome and a count, never a token, id, or URL.
@immutable
class FavoritesSyncResult {
  const FavoritesSyncResult(this.outcome, {this.favoriteCount = 0});

  const FavoritesSyncResult.notConfigured()
      : this(RemoteSyncOutcome.notConfigured);

  const FavoritesSyncResult.failed() : this(RemoteSyncOutcome.failed);

  const FavoritesSyncResult.synced(int favoriteCount)
      : this(RemoteSyncOutcome.synced, favoriteCount: favoriteCount);

  final RemoteSyncOutcome outcome;

  /// How many server-synced favourites were present after a successful refresh.
  final int favoriteCount;

  bool get didSync => outcome == RemoteSyncOutcome.synced;
  bool get didFail => outcome == RemoteSyncOutcome.failed;
}

/// Result of `PlaylistRepository.refreshFromRemote`. Display-safe: it carries
/// only an outcome and a count, never a token, id, or URL.
@immutable
class PlaylistSyncResult {
  const PlaylistSyncResult(this.outcome, {this.playlistCount = 0});

  const PlaylistSyncResult.notConfigured()
      : this(RemoteSyncOutcome.notConfigured);

  const PlaylistSyncResult.failed() : this(RemoteSyncOutcome.failed);

  const PlaylistSyncResult.synced(int playlistCount)
      : this(RemoteSyncOutcome.synced, playlistCount: playlistCount);

  final RemoteSyncOutcome outcome;

  /// How many remote playlists the server reported on a successful refresh.
  final int playlistCount;

  bool get didSync => outcome == RemoteSyncOutcome.synced;
  bool get didFail => outcome == RemoteSyncOutcome.failed;
}
