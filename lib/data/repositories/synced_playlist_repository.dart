import 'dart:async';

import '../../core/models/jellyfin_session.dart';
import '../../core/models/playlist.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/repositories/playlist_store.dart';
import '../../core/sources/jellyfin/jellyfin_api.dart';
import '../../core/sources/jellyfin/jellyfin_client.dart';
import '../../core/sources/jellyfin/jellyfin_exception.dart';

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
  })  : _store = store,
        _client = client,
        _session = session,
        _newId = idGenerator ?? _defaultIdGenerator(),
        _now = now ?? DateTime.now;

  final PlaylistStore _store;

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

  static String Function() _defaultIdGenerator() {
    int counter = 0;
    return () {
      counter++;
      final int stamp = DateTime.now().microsecondsSinceEpoch;
      return 'pl_${stamp.toRadixString(36)}_${counter.toRadixString(36)}';
    };
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _playlists = await _store.load();
    _loaded = true;
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
  Future<void> addTrack(String playlistId, String trackId) =>
      addTracks(playlistId, <String>[trackId]);

  @override
  Future<void> addTracks(String playlistId, List<String> trackIds) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null) return;
    final List<String> added = <String>[];
    final List<String> updated = <String>[...playlist.trackIds];
    for (final String trackId in trackIds) {
      if (trackId.isEmpty || updated.contains(trackId)) continue;
      updated.add(trackId);
      added.add(trackId);
    }
    if (added.isEmpty) return;
    await _mutate(
      playlistId,
      (Playlist p) => p.copyWith(trackIds: updated, updatedAt: _now()),
    );
    await _pushMembership(
      playlistId,
      (JellyfinClient client, JellyfinSession session, String remoteId) =>
          client.addItemsToPlaylist(session, remoteId, added),
    );
  }

  @override
  Future<void> removeTrack(String playlistId, String trackId) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null || !playlist.trackIds.contains(trackId)) return;
    final List<String> updated = <String>[
      for (final String id in playlist.trackIds)
        if (id != trackId) id,
    ];
    await _mutate(
      playlistId,
      (Playlist p) => p.copyWith(trackIds: updated, updatedAt: _now()),
    );
    await _pushMembership(
      playlistId,
      (JellyfinClient client, JellyfinSession session, String remoteId) =>
          client.removeItemsFromPlaylist(session, remoteId, <String>[trackId]),
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
  Future<void> refreshFromRemote() async {
    await _ensureLoaded();
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _liveSession();
    if (client == null || session == null) return;
    final List<JellyfinPlaylistDto> remote;
    try {
      remote = await client.fetchPlaylists(session);
    } on JellyfinException catch (_) {
      // Offline or transient: keep what we have.
      return;
    }

    final Map<String, Playlist> byRemoteId = <String, Playlist>{
      for (final Playlist p in _playlists)
        if (p.remoteId != null) p.remoteId!: p,
    };

    final List<Playlist> next = <Playlist>[..._playlists];
    bool changed = false;
    for (final JellyfinPlaylistDto dto in remote) {
      List<String> itemIds;
      try {
        final List<JellyfinPlaylistEntry> entries =
            await client.fetchPlaylistEntries(session, dto.id);
        itemIds = <String>[
          for (final JellyfinPlaylistEntry e in entries) e.itemId,
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
            trackIds: itemIds,
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
            trackIds: itemIds,
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
  }

  // --- Internal helpers --------------------------------------------------

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
        itemIds: playlist.trackIds,
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
