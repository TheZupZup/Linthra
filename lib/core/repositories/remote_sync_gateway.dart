import 'package:flutter/foundation.dart';

import '../models/playlist.dart';

/// A friendly, secret-free failure from a remote favourites/playlist gateway.
///
/// Each provider's gateway catches its own transport/API exception (e.g.
/// `JellyfinException`, `SubsonicException`) and rethrows this common type
/// carrying only a display-safe [message] — so the provider-agnostic
/// repositories can report an honest sync status without importing any one
/// provider's error type, and without a token or URL ever reaching a log or the
/// UI.
@immutable
class RemoteSyncException implements Exception {
  const RemoteSyncException(this.message);

  /// A friendly, secret-free explanation (never a token, salt, id, or URL).
  final String message;

  @override
  String toString() => 'RemoteSyncException: $message';
}

/// The per-provider seam through which the favourites repository mirrors hearts
/// to and from one server (Jellyfin, Subsonic/Navidrome, …).
///
/// A gateway owns exactly one provider's `scheme:` (`jellyfin:`, `subsonic:`),
/// maps Linthra's provider-namespaced [uriScheme]`<id>` uris to the bare ids its
/// server API speaks at the request boundary, and never persists or logs a
/// credential. This is what lets a single [FavoritesRepository] sync several
/// providers at once by dispatching per track uri.
abstract interface class RemoteFavoritesGateway {
  /// The track-uri scheme this gateway owns, e.g. `'jellyfin:'` or
  /// `'subsonic:'`. A favourite whose uri starts with this belongs here.
  String get uriScheme;

  /// Whether a live signed-in session is available to sync with. When false the
  /// repository keeps the optimistic local state and pushes nothing.
  bool get isConnected;

  /// The server's current favourite track uris, already namespaced with
  /// [uriScheme] (so they key exactly like the catalog and the UI). Throws a
  /// [RemoteSyncException] on failure.
  Future<Set<String>> fetchFavoriteUris();

  /// Pushes a favourite ([favorite] true) or unfavourite for [trackUri] to the
  /// server. Throws a [RemoteSyncException] on failure; the repository treats
  /// the push as best-effort and reconciles on the next refresh.
  Future<void> pushFavorite(String trackUri, bool favorite);
}

/// A remote playlist header plus its ordered, provider-namespaced member uris,
/// as imported from one server.
@immutable
class RemotePlaylistData {
  const RemotePlaylistData({
    required this.remoteId,
    required this.name,
    required this.trackUris,
  });

  /// The server's stable playlist id (non-secret).
  final String remoteId;

  final String name;

  /// Ordered, provider-namespaced member uris (`jellyfin:101`, `subsonic:mf-7`).
  final List<String> trackUris;
}

/// The per-provider seam through which the playlist repository mirrors playlists
/// to and from one server.
///
/// Membership edits are pushed through [syncMembership], which each provider
/// implements with whatever its API supports — incremental add/remove for
/// Jellyfin, a single full ordered replace for Subsonic — from the same inputs.
/// [pushesRename]/[pushesReorder] tell the repository which edits actually reach
/// the server, so an unsupported edit stays local-only instead of silently
/// pretending to sync. All ids/uris are non-secret; no credential is persisted
/// or logged, and failures surface as a [RemoteSyncException].
abstract interface class RemotePlaylistGateway {
  /// The playlist source this gateway serves (`PlaylistSource.jellyfin`,
  /// `PlaylistSource.subsonic`).
  PlaylistSource get source;

  /// Whether a live signed-in session is available to sync with.
  bool get isConnected;

  /// Whether a rename is pushed to the server. False keeps rename local-only.
  bool get pushesRename;

  /// Whether a reorder is pushed to the server. False keeps reorder local-only
  /// (a refresh then re-adopts the server order).
  bool get pushesReorder;

  /// The server's playlists with their ordered membership. Throws a
  /// [RemoteSyncException] on failure.
  Future<List<RemotePlaylistData>> fetchPlaylists();

  /// Creates a server playlist named [name] seeded with [trackUris] (in order),
  /// returning its remote id. Throws a [RemoteSyncException] on failure.
  Future<String> createRemotePlaylist(String name, List<String> trackUris);

  /// Reconciles the server playlist [remoteId]'s membership after a local edit.
  ///
  /// [orderedTrackUris] is the full desired membership in order; [added]/[removed]
  /// are the delta since the last state. A gateway uses whichever fits its API:
  /// incremental add/remove (Jellyfin) or a full ordered replace (Subsonic).
  /// Throws a [RemoteSyncException] on failure.
  Future<void> syncMembership(
    String remoteId, {
    required List<String> orderedTrackUris,
    required List<String> added,
    required List<String> removed,
  });

  /// Renames the server playlist [remoteId] to [name]. Only called when
  /// [pushesRename] is true. Throws a [RemoteSyncException] on failure.
  Future<void> renameRemote(String remoteId, String name);

  /// Deletes the server playlist [remoteId]. Only called after an explicit user
  /// confirmation. Throws a [RemoteSyncException] on failure.
  Future<void> deleteRemote(String remoteId);
}
