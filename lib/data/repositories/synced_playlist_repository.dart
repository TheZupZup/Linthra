import 'dart:async';

import '../../core/models/jellyfin_session.dart';
import '../../core/models/playlist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/repositories/playlist_store.dart';
import '../../core/repositories/remote_sync_result.dart';
import '../../core/sources/jellyfin/jellyfin_api.dart';
import '../../core/sources/jellyfin/jellyfin_client.dart';
import '../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../core/sources/music_provider.dart';

/// The app's [PlaylistRepository]: a local, persisted set of playlists with
/// optional best-effort Jellyfin sync layered on top.
///
/// Local playlists never touch a server. A playlist whose [Playlist.source] is
/// [PlaylistSource.jellyfin] is mirrored: create, membership changes (add /
/// remove track), and delete are pushed to the signed-in server best-effort,
/// and [refreshFromRemote] imports server playlists and adopts server
/// membership for already-synced ones. A server failure never throws out of an
/// editing method — the local change stands and the playlist's
/// [Playlist.syncState] flips to [PlaylistSyncState.syncFailed] with a friendly,
/// secret-free [Playlist.lastSyncError], so the UI shows an honest status rather
/// than pretending the sync worked.
///
/// Security: only non-secret metadata and track ids are stored or sent. The
/// session (with its token) is read lazily through [_session] for the request —
/// never logged or persisted here.
class SyncedPlaylistRepository implements PlaylistRepository {
  SyncedPlaylistRepository({
    required PlaylistStore store,
    JellyfinClient? client,
    JellyfinSession? Function()? session,
    String Function()? idGenerator,
    DateTime Function()? now,
    Future<List<Track>> Function()? catalogForMigration,
  })  : _store = store,
        _client = client,
        _session = session,
        _newId = idGenerator ?? _defaultIdGenerator(),
        _now = now ?? DateTime.now,
        _catalogForMigration = catalogForMigration;

  final PlaylistStore _store;

  /// Supplies the current catalog for the one-time bare-id → uri membership
  /// migration of *local* playlists, or null when none is needed (tests, the
  /// data-layer default). A Jellyfin playlist needs no oracle — its bare ids are
  /// unambiguously Jellyfin items.
  final Future<List<Track>> Function()? _catalogForMigration;

  /// The Jellyfin HTTP seam, or `null` when playlists are local-only (tests, the
  /// data-layer default). Read lazily alongside [_session].
  final JellyfinClient? _client;

  /// Supplies the live signed-in session, or `null` when not connected. Read at
  /// call time so signing in/out is picked up without rebuilding the repository.
  final JellyfinSession? Function()? _session;

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

  JellyfinSession? _liveSession() => _session?.call();

  bool get _canSync => _client != null && _liveSession() != null;

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
    final bool remote = source == PlaylistSource.jellyfin && _canSync;
    Playlist playlist = Playlist(
      id: _newId(),
      name: name,
      description: description,
      source: remote ? PlaylistSource.jellyfin : PlaylistSource.local,
      createdAt: now,
      updatedAt: now,
      syncState: remote
          ? PlaylistSyncState.pendingCreate
          : PlaylistSyncState.localOnly,
    );
    _playlists = <Playlist>[..._playlists, playlist];
    await _persistAndEmit();
    if (remote) {
      playlist = await _pushCreate(playlist);
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
    // Rename/description are local-only for now (not pushed to the server); see
    // docs/playlists-and-delete.md for the documented sync limitations.
    await _mutate(
      id,
      (Playlist p) => p.copyWith(
        name: name,
        description: description != null ? () => description : null,
        updatedAt: _now(),
      ),
    );
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
    // Best-effort server delete for a synced playlist; a failure can't restore
    // the local copy, so it is intentionally swallowed (the local delete stands).
    if (playlist.isRemote && playlist.remoteId != null && _canSync) {
      final JellyfinClient client = _client!;
      final JellyfinSession session = _liveSession()!;
      try {
        await client.deletePlaylist(session, playlist.remoteId!);
      } on JellyfinException catch (_) {
        // Swallowed: the playlist is already gone locally. It may reappear on a
        // later refresh if the server still has it (documented limitation).
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
    await _pushMembership(
      playlistId,
      (JellyfinClient client, JellyfinSession session, String remoteId) =>
          // The server speaks bare item ids; a synced playlist only holds
          // jellyfin: uris, so map them back at the request boundary.
          client.addItemsToPlaylist(session, remoteId, _jellyfinItemIds(added)),
    );
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
      (JellyfinClient client, JellyfinSession session, String remoteId) =>
          client.removeItemsFromPlaylist(
              session, remoteId, _jellyfinItemIds(<String>[trackUri])),
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
    // Reorder is local-only for now (Jellyfin item-move sync is a documented
    // follow-up); a refresh of a synced playlist re-adopts the server order.
    await _mutate(
      playlistId,
      (Playlist p) => p.copyWith(trackIds: ids, updatedAt: _now()),
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
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _liveSession();
    if (client == null || session == null) {
      return const PlaylistSyncResult.notConfigured();
    }
    final List<JellyfinPlaylistDto> remote;
    try {
      remote = await client.fetchPlaylists(session);
    } on JellyfinException catch (_) {
      // Offline or transient: keep what we have and report a friendly failure.
      return const PlaylistSyncResult.failed();
    }

    final Set<String> serverIds = <String>{
      for (final JellyfinPlaylistDto dto in remote) dto.id,
    };
    final Map<String, Playlist> byRemoteId = <String, Playlist>{
      for (final Playlist p in _playlists)
        if (p.remoteId != null) p.remoteId!: p,
    };

    // Start from the playlists we keep, dropping any synced Jellyfin playlist
    // whose server copy is gone — it was deleted on the server, and the server
    // is the source of truth for synced playlists. Local-only playlists and
    // not-yet-created ones (no remoteId) are always kept.
    final List<Playlist> next = <Playlist>[
      for (final Playlist p in _playlists)
        if (!_isStaleSyncedRemote(p, serverIds)) p,
    ];
    bool changed = next.length != _playlists.length;
    for (final JellyfinPlaylistDto dto in remote) {
      List<String> trackUris;
      try {
        final List<JellyfinPlaylistEntry> entries =
            await client.fetchPlaylistEntries(session, dto.id);
        // The server returns bare item ids; namespace them to jellyfin: uris so
        // imported membership keys the same way local edits and the catalog do.
        trackUris = <String>[
          for (final JellyfinPlaylistEntry e in entries) _jellyfinUri(e.itemId),
        ];
      } on JellyfinException catch (_) {
        // Skip this playlist's membership refresh; keep the rest going.
        continue;
      }

      final Playlist? existing = byRemoteId[dto.id];
      if (existing == null) {
        next.add(
          Playlist(
            id: _newId(),
            name: dto.name,
            source: PlaylistSource.jellyfin,
            remoteId: dto.id,
            trackIds: trackUris,
            createdAt: _now(),
            updatedAt: _now(),
            syncState: PlaylistSyncState.synced,
          ),
        );
        changed = true;
      } else {
        final int index = next.indexWhere((Playlist p) => p.id == existing.id);
        if (index >= 0) {
          next[index] = existing.copyWith(
            name: dto.name,
            trackIds: trackUris,
            syncState: PlaylistSyncState.synced,
            lastSyncError: () => null,
            updatedAt: _now(),
          );
          changed = true;
        }
      }
    }

    if (changed) {
      _playlists = next;
      await _persistAndEmit();
    }
    return PlaylistSyncResult.synced(remote.length);
  }

  @override
  Future<void> clearRemote() async {
    await _ensureLoaded();
    final int before = _playlists.length;
    _playlists = <Playlist>[
      for (final Playlist p in _playlists)
        if (p.source != PlaylistSource.jellyfin) p,
    ];
    if (_playlists.length != before) {
      await _persistAndEmit();
    }
  }

  /// Whether [p] is a synced Jellyfin playlist (has a server [Playlist.remoteId])
  /// that no longer exists in [serverIds] — i.e. it was deleted on the server, so
  /// its local mirror should be dropped on the next refresh.
  static bool _isStaleSyncedRemote(Playlist p, Set<String> serverIds) {
    return p.source == PlaylistSource.jellyfin &&
        p.remoteId != null &&
        !serverIds.contains(p.remoteId);
  }

  // --- Internal helpers --------------------------------------------------

  /// Re-keys a pre-uri store's bare-`id` membership onto the provider-namespaced
  /// [Track.uri], once, after the catalog is available.
  ///
  /// A Jellyfin-synced playlist could only ever hold Jellyfin items, so each of
  /// its bare ids is namespaced with the `jellyfin:` scheme unambiguously. A
  /// local playlist's members are resolved against the catalog: a local path is
  /// already its own uri; a bare remote id adopts its catalog owner's uri when a
  /// single provider exposes it, and is left untouched when more than one does —
  /// or when the catalog doesn't have it — so a member is never mis-attributed
  /// to the wrong provider. Persists locally only (never pushes to the server).
  Future<void> _migrateLegacyTrackIdsOnce() async {
    if (_migratedLegacyTrackIds) return;
    final bool anyMembers =
        _playlists.any((Playlist p) => p.trackIds.isNotEmpty);
    if (!anyMembers) {
      _migratedLegacyTrackIds = true;
      return;
    }

    // Resolve local-playlist members against the catalog. A Jellyfin playlist
    // needs no oracle, so only fetch when a local playlist actually has members.
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
  /// (preserving first-seen order), so a playlist can't end up with two entries
  /// for the same track.
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
    // A synced playlist's bare ids are unambiguously Jellyfin item ids.
    if (source == PlaylistSource.jellyfin) return _jellyfinUri(id);
    // Local playlist: a local path is already its own uri.
    if (catalogUris.contains(id)) return id;
    // A bare remote id adopts its unique catalog owner (ambiguous/unknown → as-is).
    return ownerByBareId[id] ?? id;
  }

  /// The provider uri for a bare Jellyfin item id (`101` → `jellyfin:101`).
  static String _jellyfinUri(String itemId) =>
      '${JellyfinTrackMapper.uriScheme}$itemId';

  /// The bare Jellyfin item ids for the `jellyfin:` uris in [uris], in order.
  /// Non-Jellyfin uris are dropped: a Jellyfin server playlist can only hold
  /// Jellyfin items, so this is what the server API is given.
  static List<String> _jellyfinItemIds(List<String> uris) => <String>[
        for (final String uri in uris)
          if (uri.startsWith(JellyfinTrackMapper.uriScheme))
            uri.substring(JellyfinTrackMapper.uriScheme.length),
      ];

  /// Pushes a freshly created playlist to the server, returning the updated
  /// playlist (with a [Playlist.remoteId] + [PlaylistSyncState.synced] on
  /// success, or [PlaylistSyncState.syncFailed] + a friendly error on failure).
  Future<Playlist> _pushCreate(Playlist playlist) async {
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _liveSession();
    if (client == null || session == null) return playlist;
    try {
      final String remoteId = await client.createPlaylist(
        session,
        name: playlist.name,
        // Map the playlist's jellyfin: uris back to the bare item ids the
        // server API expects (non-Jellyfin uris, if any, are dropped).
        itemIds: _jellyfinItemIds(playlist.trackIds),
      );
      return await _mutate(
        playlist.id,
        (Playlist p) => p.copyWith(
          remoteId: () => remoteId,
          syncState: PlaylistSyncState.synced,
          lastSyncError: () => null,
        ),
      );
    } on JellyfinException catch (error) {
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
  Future<void> _pushMembership(
    String playlistId,
    Future<void> Function(
      JellyfinClient client,
      JellyfinSession session,
      String remoteId,
    ) push,
  ) async {
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null || !playlist.isRemote || playlist.remoteId == null) {
      return;
    }
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _liveSession();
    if (client == null || session == null) return;
    try {
      await push(client, session, playlist.remoteId!);
      await _mutate(
        playlistId,
        (Playlist p) => p.copyWith(
          syncState: PlaylistSyncState.synced,
          lastSyncError: () => null,
        ),
      );
    } on JellyfinException catch (error) {
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
