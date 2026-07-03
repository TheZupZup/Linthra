import 'package:flutter/foundation.dart';

/// Which kind of backend a playlist belongs to.
///
/// A playlist is either purely on-device ([local]) or mirrored to a server
/// ([jellyfin] or [subsonic]). The enum — rather than a free string — keeps the
/// membership closed and the capability/sync logic exhaustive, while leaving
/// room to add future providers (WebDAV, …) by extending it here.
enum PlaylistSource {
  local,
  jellyfin,
  subsonic;

  /// The provider id this source maps to, matching `MusicProviders.sourceId`
  /// (`'local'`, `'jellyfin'`, `'subsonic'`) so capability lookups and routing
  /// never disagree.
  String get providerId => name;

  /// A short, friendly server label for a synced playlist's subtle source tag,
  /// or `null` for a local-only playlist. Subsonic shows "Navidrome" — the
  /// common product Linthra speaks the Subsonic API to.
  String? get serverLabel {
    switch (this) {
      case PlaylistSource.local:
        return null;
      case PlaylistSource.jellyfin:
        return 'Jellyfin';
      case PlaylistSource.subsonic:
        return 'Navidrome';
    }
  }

  /// Parses a stored [providerId] back to a source, defaulting to [local] for an
  /// unknown value so an old/forward record can never crash a load.
  static PlaylistSource fromProviderId(String? id) {
    for (final PlaylistSource source in PlaylistSource.values) {
      if (source.providerId == id) return source;
    }
    return PlaylistSource.local;
  }
}

/// Where a playlist stands relative to its remote (server) copy.
///
/// Local-only playlists are always [localOnly]. A playlist that should mirror a
/// server moves through the `pending*` states while a change is queued, lands on
/// [synced] when the server accepted it, and on [syncFailed] when it did not —
/// so the UI can show an honest "couldn't sync" rather than pretend success.
enum PlaylistSyncState {
  localOnly,
  synced,
  pendingCreate,
  pendingUpdate,
  pendingDelete,
  syncFailed;

  /// Parses a stored state name, defaulting to [localOnly] for an unknown value.
  static PlaylistSyncState fromName(String? name) {
    for (final PlaylistSyncState state in PlaylistSyncState.values) {
      if (state.name == name) return state;
    }
    return PlaylistSyncState.localOnly;
  }
}

/// A user-created, ordered collection of tracks.
///
/// Stores provider-namespaced [Track.uri]s (`jellyfin:101`, `subsonic:101`, a
/// local path) rather than full [Track] objects, so ordering and membership
/// persist cheaply and survive a catalog re-scan — and so a member `jellyfin:101`
/// is never confused with `subsonic:101`. A Jellyfin-synced playlist holds only
/// `jellyfin:` uris; the repository maps each to its bare item id at the server
/// boundary, since the Jellyfin API speaks bare ids.
///
/// Security invariant: a playlist is *persisted* metadata, so it must never
/// carry a secret. [remoteId] is the non-secret server playlist id; do not add a
/// Jellyfin token or an authenticated URL to this record, and keep
/// [lastSyncError] a friendly, secret-free message.
@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.description,
    this.source = PlaylistSource.local,
    this.remoteId,
    this.trackIds = const <String>[],
    this.createdAt,
    this.updatedAt,
    this.syncState = PlaylistSyncState.localOnly,
    this.lastSyncError,
  });

  /// Stable Linthra playlist id (an opaque local id, never a server secret).
  final String id;

  final String name;

  /// Optional free-text description.
  final String? description;

  /// The backend this playlist belongs to.
  final PlaylistSource source;

  /// The server's playlist id once this playlist is mirrored, or `null` for a
  /// local-only playlist (or one whose remote create has not landed yet).
  final String? remoteId;

  /// Ordered, provider-namespaced track uris. Empty for a brand-new playlist.
  final List<String> trackIds;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Where this playlist stands relative to its remote copy.
  final PlaylistSyncState syncState;

  /// A friendly, secret-free explanation of the last failed sync, or `null` when
  /// the last sync attempt succeeded (or none has run).
  final String? lastSyncError;

  int get length => trackIds.length;

  bool get isEmpty => trackIds.isEmpty;

  /// Whether this playlist is mirrored to a server (its [source] is remote).
  bool get isRemote => source != PlaylistSource.local;

  Playlist copyWith({
    String? id,
    String? name,
    String? Function()? description,
    PlaylistSource? source,
    String? Function()? remoteId,
    List<String>? trackIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    PlaylistSyncState? syncState,
    String? Function()? lastSyncError,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description != null ? description() : this.description,
      source: source ?? this.source,
      remoteId: remoteId != null ? remoteId() : this.remoteId,
      trackIds: trackIds ?? this.trackIds,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      syncState: syncState ?? this.syncState,
      lastSyncError:
          lastSyncError != null ? lastSyncError() : this.lastSyncError,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Playlist && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
