import 'dart:async';

import '../../core/models/playlist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/repositories/playlist_store.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/repositories/remote_sync_result.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../core/sources/music_provider.dart';
import '../../core/sources/subsonic/subsonic_track_mapper.dart';

/// The app's [PlaylistRepository]: a local, persisted set of playlists with
/// optional best-effort server sync layered on top, across any number of
/// providers.
///
/// Local playlists never touch a server. A playlist whose [Playlist.source] is
/// a remote provider ([PlaylistSource.jellyfin], [PlaylistSource.subsonic]) is
/// mirrored through that provider's [RemotePlaylistGateway]: create, membership
/// changes (add / remove / reorder), rename, and delete are pushed best-effort —
/// each provider using whatever its API supports — and [refreshFromRemote]
/// imports server playlists and adopts server membership for already-synced
/// ones. A server failure never throws out of an editing method: the local
/// change stands and the playlist's [Playlist.syncState] flips to
/// [PlaylistSyncState.syncFailed] with a friendly, secret-free
/// [Playlist.lastSyncError], so the UI shows an honest status.
///
/// Security: only non-secret metadata and track ids are stored or sent. Sessions
/// (with their tokens) live behind the gateways — never logged or persisted here.
class SyncedPlaylistRepository implements PlaylistRepository {
  SyncedPlaylistRepository({
    required PlaylistStore store,
    List<RemotePlaylistGateway> gateways = const <RemotePlaylistGateway>[],
    String Function()? idGenerator,
    DateTime Function()? now,
    Future<List<Track>> Function()? catalogForMigration,
  })  : _store = store,
        _gateways = gateways,
        _newId = idGenerator ?? _defaultIdGenerator(),
        _now = now ?? DateTime.now,
        _catalogForMigration = catalogForMigration;

  final PlaylistStore _store;

  /// The per-provider server seams. Empty for local-only (tests, the data-layer
  /// default); the composition root supplies one per remote provider.
  final List<RemotePlaylistGateway> _gateways;

  /// Supplies the current catalog for the one-time bare-id → uri membership
  /// migration of *local* playlists, or null when none is needed (tests, the
  /// data-layer default). A remote-synced playlist needs no oracle — its bare
  /// ids are unambiguously that provider's items.
  final Future<List<Track>> Function()? _catalogForMigration;

  final String Function() _newId;
  final DateTime Function() _now;

  final StreamController<List<Playlist>> _changes =
      StreamController<List<Playlist>>.broadcast();

  List<Playlist> _playlists = <Playlist>[];
  bool _loaded = false;

  /// Guards the one-time legacy bare-id → uri membership migration so it runs at
  /// most once, after the catalog is available (see [_migrateLegacyTrackIdsOnce]).
  bool _migratedLegacyTrackIds = false;

  static String Function() _defaultIdGenerator() {
    int counter = 0;
    return () {
      counter++;
      final int stamp = DateTime.now().microsecondsSinceEpoch;
      return 'pl_${stamp.toRadixString(36)}_${counter.toRadixString(36)}';
    };
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) {
      _playlists = await _store.load();
      _loaded = true;
    }
    await _migrateLegacyTrackIdsOnce();
  }

  /// The connected gateway that serves [source], or `null` when that provider is
  /// local-only, not registered, or not signed in.
  RemotePlaylistGateway? _gatewayForSource(PlaylistSource source) {
    for (final RemotePlaylistGateway gateway in _gateways) {
      if (gateway.source == source && gateway.isConnected) return gateway;
    }
    return null;
  }

  @override
  Stream<List<Playlist>> get playlistsStream async* {
    await _ensureLoaded();
    yield _snapshot();
    yield* _changes.stream;
  }

  @override
  Future<List<Playlist>> getAllPlaylists() async {
    await _ensureLoaded();
    return _snapshot();
  }

  @override
  Future<Playlist?> getPlaylistById(String id) async {
    await _ensureLoaded();
    for (final Playlist playlist in _playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  @override
  Future<Playlist> createPlaylist(
    String name, {
    String? description,
    PlaylistSource source = PlaylistSource.local,
  }) async {
    await _ensureLoaded();
    final DateTime now = _now();
    final RemotePlaylistGateway? gateway =
        source == PlaylistSource.local ? null : _gatewayForSource(source);
    final bool remote = gateway != null;
    Playlist playlist = Playlist(
      id: _newId(),
      name: name,
      description: description,
      source: remote ? source : PlaylistSource.local,
      createdAt: now,
      updatedAt: now,
      syncState: remote
          ? PlaylistSyncState.pendingCreate
          : PlaylistSyncState.localOnly,
    );
    _playlists = <Playlist>[..._playlists, playlist];
    await _persistAndEmit();
    if (remote) {
      playlist = await _pushCreate(playlist, gateway);
    }
    return playlist;
  }

  @override
  Future<void> renamePlaylist(
    String id,
    String name, {
    String? description,
  }) async {
    await _ensureLoaded();
    await _mutate(
      id,
      (Playlist p) => p.copyWith(
        name: name,
        description: description != null ? () => description : null,
        updatedAt: _now(),
      ),
    );
    // Push the rename only for a synced playlist whose provider supports it
    // (Subsonic does; Jellyfin rename stays local-only — a refresh re-adopts the
    // server name). See docs/playlists-and-delete.md.
    final Playlist? playlist = _byId(id);
    if (playlist == null || !playlist.isRemote || playlist.remoteId == null) {
      return;
    }
    final RemotePlaylistGateway? gateway = _gatewayForSource(playlist.source);
    if (gateway == null || !gateway.pushesRename) return;
    try {
      await gateway.renameRemote(playlist.remoteId!, name);
      await _mutate(
        id,
        (Playlist p) => p.copyWith(
          syncState: PlaylistSyncState.synced,
          lastSyncError: () => null,
        ),
      );
    } on RemoteSyncException catch (error) {
      await _mutate(
        id,
        (Playlist p) => p.copyWith(
          syncState: PlaylistSyncState.syncFailed,
          lastSyncError: () => error.message,
        ),
      );
    }
  }

  @override
  Future<void> deletePlaylist(String id) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(id);
    if (playlist == null) return;
    _playlists = <Playlist>[
      for (final Playlist p in _playlists)
        if (p.id != id) p,
    ];
    await _persistAndEmit();
    // Best-effort server delete for a synced playlist (only ever reached after
    // the UI's explicit delete confirmation). A failure can't restore the local
    // copy, so it is intentionally swallowed — the local delete stands.
    if (playlist.isRemote && playlist.remoteId != null) {
      final RemotePlaylistGateway? gateway = _gatewayForSource(playlist.source);
      if (gateway != null) {
        try {
          await gateway.deleteRemote(playlist.remoteId!);
        } on RemoteSyncException catch (_) {
          // Swallowed: the playlist is already gone locally. It may reappear on a
          // later refresh if the server still has it (documented limitation).
        }
      }
    }
  }

  @override
  Future<void> addTrack(String playlistId, String trackUri) =>
      addTracks(playlistId, <String>[trackUri]);

  @override
  Future<void> addTracks(String playlistId, List<String> trackUris) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null) return;
    final List<String> added = <String>[];
    final List<String> updated = <String>[...playlist.trackIds];
    for (final String trackUri in trackUris) {
      if (trackUri.isEmpty || updated.contains(trackUri)) continue;
      updated.add(trackUri);
      added.add(trackUri);
    }
    if (added.isEmpty) return;
    await _mutate(
      playlistId,
      (Playlist p) => p.copyWith(trackIds: updated, updatedAt: _now()),
    );
    await _pushMembership(playlistId, added: added, removed: const <String>[]);
  }

  @override
  Future<void> removeTrack(String playlistId, String trackUri) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null || !playlist.trackIds.contains(trackUri)) return;
    final List<String> updated = <String>[
      for (final String uri in playlist.trackIds)
        if (uri != trackUri) uri,
    ];
    await _mutate(
      playlistId,
      (Playlist p) => p.copyWith(trackIds: updated, updatedAt: _now()),
    );
    await _pushMembership(
      playlistId,
      added: const <String>[],
      removed: <String>[trackUri],
    );
  }

  @override
  Future<void> reorderTracks(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null) return;
    final List<String> ids = <String>[...playlist.trackIds];
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    // Mirror ReorderableListView's index convention: a downward move reports a
    // newIndex one past the intended slot once the item is removed.
    int target = newIndex;
    if (target > oldIndex) target -= 1;
    target = target.clamp(0, ids.length - 1);
    if (target == oldIndex) return;
    final String moved = ids.removeAt(oldIndex);
    ids.insert(target, moved);
    await _mutate(
      playlistId,
      (Playlist p) => p.copyWith(trackIds: ids, updatedAt: _now()),
    );
    // Push reorder only for a provider that mirrors order (Subsonic replaces the
    // full ordered list; Jellyfin reorder stays local-only, and a refresh
    // re-adopts the server order).
    final Playlist? current = _byId(playlistId);
    if (current == null || !current.isRemote || current.remoteId == null) {
      return;
    }
    final RemotePlaylistGateway? gateway = _gatewayForSource(current.source);
    if (gateway == null || !gateway.pushesReorder) return;
    await _pushMembership(
      playlistId,
      added: const <String>[],
      removed: const <String>[],
    );
  }

  @override
  Future<void> markSyncState(
    String id,
    PlaylistSyncState state, {
    String? error,
  }) async {
    await _ensureLoaded();
    await _mutate(
      id,
      (Playlist p) => p.copyWith(
        syncState: state,
        lastSyncError: () => error,
      ),
    );
  }

  @override
  Future<PlaylistSyncResult> refreshFromRemote() async {
    await _ensureLoaded();
    final List<RemotePlaylistGateway> connected = <RemotePlaylistGateway>[
      for (final RemotePlaylistGateway g in _gateways)
        if (g.isConnected) g,
    ];
    if (connected.isEmpty) {
      return const PlaylistSyncResult.notConfigured();
    }

    List<Playlist> next = <Playlist>[..._playlists];
    bool changed = false;
    int total = 0;
    int successCount = 0;

    for (final RemotePlaylistGateway gateway in connected) {
      final List<RemotePlaylistData> remote;
      try {
        remote = await gateway.fetchPlaylists();
      } on RemoteSyncException {
        // Offline or transient for this provider: keep its synced playlists and
        // move on to the others.
        continue;
      }
      successCount++;
      total += remote.length;

      final Set<String> serverIds = <String>{
        for (final RemotePlaylistData dto in remote) dto.remoteId,
      };
      // Drop this provider's synced playlists whose server copy is gone (server
      // is the source of truth for synced playlists). Local-only playlists and
      // other providers' playlists are never touched.
      final int before = next.length;
      next = <Playlist>[
        for (final Playlist p in next)
          if (!_isStaleSyncedRemote(p, gateway.source, serverIds)) p,
      ];
      if (next.length != before) changed = true;

      final Map<String, Playlist> byRemoteId = <String, Playlist>{
        for (final Playlist p in next)
          if (p.source == gateway.source && p.remoteId != null) p.remoteId!: p,
      };

      for (final RemotePlaylistData dto in remote) {
        final Playlist? existing = byRemoteId[dto.remoteId];
        if (existing == null) {
          next = <Playlist>[
            ...next,
            Playlist(
              id: _newId(),
              name: dto.name,
              source: gateway.source,
              remoteId: dto.remoteId,
              trackIds: dto.trackUris,
              createdAt: _now(),
              updatedAt: _now(),
              syncState: PlaylistSyncState.synced,
            ),
          ];
          changed = true;
        } else {
          final int index =
              next.indexWhere((Playlist p) => p.id == existing.id);
          if (index >= 0) {
            next[index] = existing.copyWith(
              name: dto.name,
              trackIds: dto.trackUris,
              syncState: PlaylistSyncState.synced,
              lastSyncError: () => null,
              updatedAt: _now(),
            );
            changed = true;
          }
        }
      }
    }

    if (changed) {
      _playlists = next;
      await _persistAndEmit();
    }
    if (successCount == 0) return const PlaylistSyncResult.failed();
    return PlaylistSyncResult.synced(total);
  }

  @override
  Future<void> clearRemote({PlaylistSource? source}) async {
    await _ensureLoaded();
    final int before = _playlists.length;
    _playlists = <Playlist>[
      for (final Playlist p in _playlists)
        if (p.source == PlaylistSource.local ||
            (source != null && p.source != source))
          p,
    ];
    if (_playlists.length != before) {
      await _persistAndEmit();
    }
  }

  /// Whether [p] is a synced playlist of [source] (has a server
  /// [Playlist.remoteId]) that no longer exists in [serverIds] — i.e. it was
  /// deleted on the server, so its local mirror should be dropped on refresh.
  static bool _isStaleSyncedRemote(
    Playlist p,
    PlaylistSource source,
    Set<String> serverIds,
  ) {
    return p.source == source &&
        p.remoteId != null &&
        !serverIds.contains(p.remoteId);
  }

  // --- Internal helpers --------------------------------------------------

  /// Re-keys a pre-uri store's bare-`id` membership onto the provider-namespaced
  /// [Track.uri], once, after the catalog is available.
  ///
  /// A remote-synced playlist could only ever hold its provider's items, so each
  /// of its bare ids is namespaced with that scheme unambiguously. A local
  /// playlist's members are resolved against the catalog: a local path is
  /// already its own uri; a bare remote id adopts its catalog owner's uri when a
  /// single provider exposes it, and is left untouched when more than one does —
  /// or when the catalog doesn't have it. Persists locally only (never pushes).
  Future<void> _migrateLegacyTrackIdsOnce() async {
    if (_migratedLegacyTrackIds) return;
    final bool anyMembers =
        _playlists.any((Playlist p) => p.trackIds.isNotEmpty);
    if (!anyMembers) {
      _migratedLegacyTrackIds = true;
      return;
    }

    Set<String> catalogUris = const <String>{};
    Map<String, String?> ownerByBareId = const <String, String?>{};
    final Future<List<Track>> Function()? oracle = _catalogForMigration;
    final bool needCatalog = oracle != null &&
        _playlists.any((Playlist p) =>
            p.source == PlaylistSource.local && p.trackIds.isNotEmpty);
    if (needCatalog) {
      final List<Track> tracks;
      try {
        tracks = await oracle();
      } catch (_) {
        return; // Transient read failure: defer so a later call can retry.
      }
      // An empty catalog this early is "not loaded yet", not "no library";
      // defer so an unambiguous local membership isn't stranded as a bare id.
      if (tracks.isEmpty) return;
      catalogUris = <String>{for (final Track t in tracks) t.uri};
      final Map<String, String?> owners = <String, String?>{};
      for (final Track t in tracks) {
        if (t.uri == t.id) continue; // local: id == uri, never a bare-id key.
        owners[t.id] = owners.containsKey(t.id) ? null : t.uri;
      }
      ownerByBareId = owners;
    }
    _migratedLegacyTrackIds = true;

    bool changed = false;
    final List<Playlist> next = <Playlist>[];
    for (final Playlist playlist in _playlists) {
      final List<String> migrated =
          _migrateTrackIds(playlist, catalogUris, ownerByBareId);
      if (identical(migrated, playlist.trackIds)) {
        next.add(playlist);
      } else {
        changed = true;
        next.add(playlist.copyWith(trackIds: migrated));
      }
    }
    if (changed) {
      _playlists = next;
      await _persistAndEmit();
    }
  }

  /// The migrated membership for [playlist], or its existing list unchanged when
  /// nothing needed re-keying. Collapses any duplicate the re-key introduces
  /// (preserving first-seen order).
  List<String> _migrateTrackIds(
    Playlist playlist,
    Set<String> catalogUris,
    Map<String, String?> ownerByBareId,
  ) {
    if (playlist.trackIds.isEmpty) return playlist.trackIds;
    bool changed = false;
    final Set<String> seen = <String>{};
    final List<String> result = <String>[];
    for (final String id in playlist.trackIds) {
      final String mapped =
          _migrateOneTrackId(id, playlist.source, catalogUris, ownerByBareId);
      if (mapped != id) changed = true;
      if (seen.add(mapped)) {
        result.add(mapped);
      } else {
        changed = true; // a duplicate collapsed away
      }
    }
    return changed ? result : playlist.trackIds;
  }

  /// Maps one legacy membership entry to its provider uri. Entries that already
  /// carry a known scheme are returned unchanged.
  String _migrateOneTrackId(
    String id,
    PlaylistSource source,
    Set<String> catalogUris,
    Map<String, String?> ownerByBareId,
  ) {
    // Already provider-namespaced (jellyfin:/subsonic:/plex:): nothing to do.
    if (MusicProviders.bareRemoteIdForTrackUri(id) != null) return id;
    // A synced playlist's bare ids are unambiguously that provider's items.
    if (source == PlaylistSource.jellyfin) {
      return '${JellyfinTrackMapper.uriScheme}$id';
    }
    if (source == PlaylistSource.subsonic) {
      return '${SubsonicTrackMapper.uriScheme}$id';
    }
    // Local playlist: a local path is already its own uri.
    if (catalogUris.contains(id)) return id;
    // A bare remote id adopts its unique catalog owner (ambiguous/unknown → as-is).
    return ownerByBareId[id] ?? id;
  }

  /// Pushes a freshly created playlist to its server, returning the updated
  /// playlist (with a [Playlist.remoteId] + [PlaylistSyncState.synced] on
  /// success, or [PlaylistSyncState.syncFailed] + a friendly error on failure).
  Future<Playlist> _pushCreate(
    Playlist playlist,
    RemotePlaylistGateway gateway,
  ) async {
    try {
      final String remoteId = await gateway.createRemotePlaylist(
        playlist.name,
        playlist.trackIds,
      );
      return await _mutate(
        playlist.id,
        (Playlist p) => p.copyWith(
          remoteId: () => remoteId,
          syncState: PlaylistSyncState.synced,
          lastSyncError: () => null,
        ),
      );
    } on RemoteSyncException catch (error) {
      return _mutate(
        playlist.id,
        (Playlist p) => p.copyWith(
          syncState: PlaylistSyncState.syncFailed,
          lastSyncError: () => error.message,
        ),
      );
    }
  }

  /// Runs a best-effort membership change against the server for a synced
  /// playlist, flipping its sync state to synced or syncFailed accordingly. A
  /// local-only playlist (or one not yet created on the server) is left alone.
  ///
  /// [added]/[removed] are the delta; the current full ordered membership is
  /// read fresh and passed too, so a full-replace provider (Subsonic) has the
  /// exact list while an incremental one (Jellyfin) uses the delta.
  Future<void> _pushMembership(
    String playlistId, {
    required List<String> added,
    required List<String> removed,
  }) async {
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null || !playlist.isRemote || playlist.remoteId == null) {
      return;
    }
    final RemotePlaylistGateway? gateway = _gatewayForSource(playlist.source);
    if (gateway == null) return;
    try {
      await gateway.syncMembership(
        playlist.remoteId!,
        orderedTrackUris: playlist.trackIds,
        added: added,
        removed: removed,
      );
      await _mutate(
        playlistId,
        (Playlist p) => p.copyWith(
          syncState: PlaylistSyncState.synced,
          lastSyncError: () => null,
        ),
      );
    } on RemoteSyncException catch (error) {
      await _mutate(
        playlistId,
        (Playlist p) => p.copyWith(
          syncState: PlaylistSyncState.syncFailed,
          lastSyncError: () => error.message,
        ),
      );
    }
  }

  Playlist? _byId(String id) {
    for (final Playlist p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Applies [transform] to the playlist with [id] (if present), persists, and
  /// emits, returning the resulting playlist (or the unchanged one if absent).
  Future<Playlist> _mutate(
    String id,
    Playlist Function(Playlist) transform,
  ) async {
    Playlist? result;
    _playlists = <Playlist>[
      for (final Playlist p in _playlists)
        if (p.id == id) (result = transform(p)) else p,
    ];
    await _persistAndEmit();
    return result ?? Playlist(id: id, name: '');
  }

  List<Playlist> _snapshot() => List<Playlist>.unmodifiable(_playlists);

  Future<void> _persistAndEmit() async {
    _emit();
    await _store.save(_playlists);
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(_snapshot());
  }

  Future<void> dispose() => _changes.close();
}
