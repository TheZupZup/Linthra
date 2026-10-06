import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;

import '../../core/models/playlist.dart';
import '../../core/models/playlist_move.dart';
import '../../core/models/track.dart';
import '../../core/repositories/local_store_write_exception.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/repositories/playlist_store.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/repositories/remote_sync_result.dart';
import '../../core/services/stability_diagnostics.dart';
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

  /// How many times each provider's synced playlists have been cleared (its
  /// sign-out). A refresh notes the counts before fetching and discards a
  /// provider's answer if its count moved meanwhile (see [refreshFromRemote]).
  final Map<PlaylistSource, int> _clears = <PlaylistSource, int>{};

  /// The refresh currently fetching, and the clear counts of the providers it
  /// is asking, so an overlapping caller can join it.
  Future<PlaylistSyncResult>? _refreshInFlight;
  Map<PlaylistSource, int> _refreshInFlightClears =
      const <PlaylistSource, int>{};

  /// Numbers each provider fetch in the order it was sent, so a later request
  /// (a newer answer) can be told from an earlier one.
  int _fetchesSent = 0;

  /// How many refreshes have fetches out, and, while any do, which playlist
  /// object each merge left in place and the number of the fetch it came
  /// from. Two refreshes overlap when a provider signs in or out while one is
  /// out; this is how each tells the other's merge from the user's edit (see
  /// [_mergeRemote]). Only a refresh already out when a merge landed can ask
  /// about it, so it is dropped once none are.
  int _refreshesOut = 0;
  final Map<String, ({Playlist playlist, int fetch})> _mergedBy =
      <String, ({Playlist playlist, int fetch})>{};

  /// The latest rename or membership push queued for each synced playlist,
  /// until it has finished. See [_pushInOrder].
  final Map<String, Future<void>> _pushes = <String, Future<void>>{};

  /// The creates still out, each as the provider it went to and that
  /// provider's sign-out count when it left. See [_mergeRemote].
  final List<({PlaylistSource source, int clears})> _createsOut =
      <({PlaylistSource source, int clears})>[];

  /// Server playlists deleted here that a refresh answer may still list: `null`
  /// while the delete is out, then the number of the last fetch sent before it
  /// settled. Kept while a refresh that may have read the server before it is
  /// out; see [_mergeRemote] and [_settleDelete].
  final Map<({PlaylistSource source, String remoteId}), int?> _deletes =
      <({PlaylistSource source, String remoteId}), int?>{};

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
      _playlists = <Playlist>[
        for (final Playlist p in await _store.load())
          // Its create was still out when the app last closed. A create lasts
          // only as long as the app, so no answer is coming: it is a create
          // that failed, and says so rather than passing for synced.
          if (p.syncState == PlaylistSyncState.pendingCreate &&
              p.remoteId == null)
            p.copyWith(
              syncState: PlaylistSyncState.syncFailed,
              lastSyncError: () => _unfinishedCreate,
            )
          else
            p,
      ];
      _loaded = true;
    }
    await _migrateLegacyTrackIdsOnce();
  }

  /// The [Playlist.lastSyncError] of a playlist whose create never answered.
  static const String _unfinishedCreate =
      'Linthra closed before the server confirmed this playlist was created.';

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
      // On the push queue like every later push for it: the playlist is on
      // screen and editable at once, but an edit has no server id to go to
      // until this lands, so it waits for it instead of being skipped.
      final Playlist pending = playlist;
      // Out until it has settled (bound to its server id, failed, or deleted
      // on the server again); see [_mergeRemote].
      final ({PlaylistSource source, int clears}) create =
          (source: source, clears: _clearsOf(source));
      _createsOut.add(create);
      try {
        playlist = await _pushInOrder(
          pending.id,
          () => _pushCreate(pending, gateway),
        );
      } finally {
        _createsOut.remove(create);
      }
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
    // (Subsonic does; a Jellyfin rename stays local-only, and a refresh
    // re-adopts the server name). See docs/playlists-and-delete.md.
    final Playlist? playlist = _byId(id);
    if (playlist == null || !playlist.isRemote) return;
    if (!(_gatewayForSource(playlist.source)?.pushesRename ?? false)) return;
    await _pushInOrder(id, () => _sendRename(id, name));
  }

  /// Sends a rename to the server, reading the playlist when it goes out.
  Future<void> _sendRename(String id, String name) async {
    final Playlist? playlist = _byId(id);
    if (playlist == null || !playlist.isRemote || playlist.remoteId == null) {
      return;
    }
    final RemotePlaylistGateway? gateway = _gatewayForSource(playlist.source);
    if (gateway == null || !gateway.pushesRename) return;
    try {
      await gateway.renameRemote(playlist.remoteId!, name);
      await _mutate(id, _confirmedPush);
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
        final ({PlaylistSource source, String remoteId}) deleted =
            (source: playlist.source, remoteId: playlist.remoteId!);
        _deletes[deleted] = null;
        try {
          await gateway.deleteRemote(playlist.remoteId!);
        } on RemoteSyncException catch (_) {
          // Swallowed: the playlist is already gone locally. It may reappear on a
          // later refresh if the server still has it (documented limitation).
        } finally {
          _settleDelete(deleted);
        }
      }
    }
  }

  /// Notes that the server delete of [deleted] has settled. A refresh that
  /// asked the server before this may still have it in its answer; one that
  /// asks after won't, unless the delete failed (then it is back, as a failed
  /// delete always was).
  void _settleDelete(({PlaylistSource source, String remoteId}) deleted) {
    if (_refreshesOut == 0) {
      _deletes.remove(deleted);
    } else {
      _deletes[deleted] = _fetchesSent;
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
  Future<List<int>> removeTrack(String playlistId, String trackUri) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null) return const <int>[];
    final List<int> positions = <int>[
      for (int i = 0; i < playlist.trackIds.length; i++)
        if (playlist.trackIds[i] == trackUri) i,
    ];
    if (positions.isEmpty) return positions;
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
    return positions;
  }

  @override
  Future<void> restoreTrack(
    String playlistId,
    String trackUri,
    List<int> positions,
  ) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null ||
        trackUri.isEmpty ||
        positions.isEmpty ||
        playlist.trackIds.contains(trackUri)) {
      return;
    }
    // Ascending, so each copy goes back in front of the ones after it.
    final List<String> updated = <String>[...playlist.trackIds];
    for (final int position in <int>[...positions]..sort()) {
      updated.insert(position.clamp(0, updated.length), trackUri);
    }
    await _mutate(
      playlistId,
      (Playlist p) => p.copyWith(trackIds: updated, updatedAt: _now()),
    );
    // Subsonic replaces the whole ordered list, so the server gets the track
    // back in its place; Jellyfin appends it there, the same as a reorder,
    // which stays local until the next refresh adopts the server's order.
    await _pushMembership(
      playlistId,
      added: <String>[for (final int _ in positions) trackUri],
      removed: const <String>[],
    );
  }

  @override
  Future<void> reorderTracks(
    String playlistId,
    int oldIndex,
    int newIndex, {
    List<String>? shown,
  }) async {
    await _ensureLoaded();
    final Playlist? playlist = _byId(playlistId);
    if (playlist == null) return;
    // Mirror ReorderableListView's index convention: a downward move reports a
    // newIndex one past the intended slot once the item is removed.
    int target = newIndex;
    if (target > oldIndex) target -= 1;
    final List<String> ids;
    if (shown != null) {
      // The order the caller saw may not be the stored one any more, so the
      // song it moved is found by identity (#749).
      final List<String>? moved = playlistWithMove(
        playlist.trackIds,
        shown: shown,
        from: oldIndex,
        to: target,
      );
      if (moved == null || listEquals(moved, playlist.trackIds)) return;
      ids = moved;
    } else {
      ids = <String>[...playlist.trackIds];
      if (oldIndex < 0 || oldIndex >= ids.length) return;
      target = target.clamp(0, ids.length - 1);
      if (target == oldIndex) return;
      final String moved = ids.removeAt(oldIndex);
      ids.insert(target, moved);
    }
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
  Future<PlaylistSyncResult> refreshFromRemote({PlaylistSource? source}) async {
    await _ensureLoaded();
    final List<RemotePlaylistGateway> connected = <RemotePlaylistGateway>[
      for (final RemotePlaylistGateway g in _gateways)
        if (g.isConnected && (source == null || g.source == source)) g,
    ];
    if (connected.isEmpty) {
      return const PlaylistSyncResult.notConfigured();
    }

    // Startup, resume, opening the Playlists tab and the end of every library
    // sync all ask for a refresh, often at once. A caller joins the one in
    // flight rather than stacking another 1 + N round-trips per provider, but
    // only when that one is asking exactly the providers this call would ask,
    // under the same sign-in: one that started before a sign-in (or a sign-out)
    // would answer for the wrong set of accounts, and could still be waiting
    // on one that is gone.
    final Map<PlaylistSource, int> clears = <PlaylistSource, int>{
      for (final RemotePlaylistGateway g in connected)
        g.source: _clearsOf(g.source),
    };
    final Future<PlaylistSyncResult>? inFlight = _refreshInFlight;
    if (inFlight != null && mapEquals(clears, _refreshInFlightClears)) {
      return inFlight;
    }
    final Future<PlaylistSyncResult> refresh =
        _fetchAndMerge(connected, clears);
    _refreshInFlight = refresh;
    _refreshInFlightClears = clears;
    try {
      return await refresh;
    } finally {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
    }
  }

  /// Fetches every connected provider's playlists, then folds them into the
  /// playlists as they are *when the answers land*.
  ///
  /// The fetch is 1 + N requests per provider, and the user keeps editing
  /// while it runs. So nothing read from [_playlists] before an await is ever
  /// written back after it: the merge reads the current list and assigns it in
  /// one synchronous step (see [_mergeRemote]).
  Future<PlaylistSyncResult> _fetchAndMerge(
    List<RemotePlaylistGateway> connected,
    Map<PlaylistSource, int> clears,
  ) async {
    _refreshesOut++;
    try {
      return await _fetchAndMergeOnce(connected, clears);
    } finally {
      if (--_refreshesOut == 0) {
        _mergedBy.clear();
        _deletes.removeWhere((_, int? settled) => settled != null);
      }
    }
  }

  Future<PlaylistSyncResult> _fetchAndMergeOnce(
    List<RemotePlaylistGateway> connected,
    Map<PlaylistSource, int> clears,
  ) async {
    // Playlists are immutable and every edit replaces the object, so keeping
    // the ones present now lets the merge tell, by identity, which playlists
    // were created, edited or deleted while the fetch was in flight.
    final Map<String, Playlist> before = <String, Playlist>{
      for (final Playlist p in _playlists) p.id: p,
    };

    final Map<RemotePlaylistGateway,
            ({RemotePlaylistListing answer, int fetch})> fetched =
        <RemotePlaylistGateway, ({RemotePlaylistListing answer, int fetch})>{};
    int failures = 0;
    for (final RemotePlaylistGateway gateway in connected) {
      // Signed out while an earlier provider answered: don't ask for an
      // account that is gone.
      if (!gateway.isConnected ||
          _clearsOf(gateway.source) != clears[gateway.source]) {
        continue;
      }
      final int fetch = ++_fetchesSent;
      try {
        fetched[gateway] =
            (answer: await gateway.fetchPlaylists(), fetch: fetch);
      } on RemoteSyncException {
        // Offline or transient for this provider: keep its synced playlists and
        // move on to the others.
        failures++;
      }
    }

    // From here to the assignments in [_mergeRemote] there is no await.
    bool changed = false;
    int total = 0;
    int complete = 0;
    for (final MapEntry<RemotePlaylistGateway,
        ({RemotePlaylistListing answer, int fetch})> entry in fetched.entries) {
      final RemotePlaylistGateway gateway = entry.key;
      // Signed out (or cleared) while the fetch was in flight: the answer is
      // that account's, which is gone. A Subsonic fetch keeps the session it
      // started with, so the gateway can still look connected; the clear count
      // is what says so.
      if (!gateway.isConnected ||
          _clearsOf(gateway.source) != clears[gateway.source]) {
        continue;
      }
      final RemotePlaylistListing answer = entry.value.answer;
      total += answer.playlists.length;
      if (answer.unread.isEmpty) {
        complete++;
      } else {
        // What it read is merged, but some playlists it listed could not be
        // read: report it like a provider that could not be reached.
        failures++;
      }
      if (_mergeRemote(
        gateway.source,
        answer,
        before,
        entry.value.fetch,
      )) {
        changed = true;
      }
    }

    if (changed) await _persistAndEmit();
    if (complete == 0) {
      return failures > 0
          ? const PlaylistSyncResult.failed()
          : const PlaylistSyncResult.notConfigured();
    }
    return PlaylistSyncResult.synced(total);
  }

  /// Folds one provider's server playlists ([listing], the answer to request
  /// number [fetch], sent while [before] was the list) into the current
  /// [_playlists], returning whether anything changed. Synchronous on purpose:
  /// see [_fetchAndMerge].
  ///
  /// The server is the source of truth for synced playlists, but only as of
  /// the fetch. A synced playlist the user created, edited or deleted while it
  /// was in flight is newer than that answer, so it is left as the user left
  /// it: not reverted to the older server copy, not dropped because the answer
  /// predates its create, and not re-imported after a local delete. Its edit
  /// was pushed (or marked syncFailed) as usual, and the next refresh
  /// reconciles it against a server that has seen it. Local-only playlists are
  /// never touched.
  ///
  /// Only a playlist missing from the listing was deleted on the server. One
  /// the server listed but whose tracks could not be read
  /// ([RemotePlaylistListing.unread]) is not known to have changed at all, so
  /// it is kept exactly as it is, under the same id and with any unpushed
  /// edit, until a refresh can read it.
  ///
  /// A refresh that overlaps this one (a provider signed in while it was out)
  /// replaces playlists too, and that is not an edit: whichever of the two
  /// asked the server later has the newer answer, and it wins, whichever
  /// order they land in.
  bool _mergeRemote(
    PlaylistSource source,
    RemotePlaylistListing listing,
    Map<String, Playlist> before,
    int fetch,
  ) {
    final List<RemotePlaylistData> remote = listing.playlists;
    final Map<String, RemotePlaylistData> server = <String, RemotePlaylistData>{
      for (final RemotePlaylistData dto in remote) dto.remoteId: dto,
    };
    // The remote ids an import must skip: every one this provider has locally
    // now (filled in below), and every one it had when the fetch started, since
    // one of those that is gone now was deleted during the fetch and the older
    // answer must not bring it back.
    final Set<String> known = <String>{
      for (final Playlist p in before.values)
        if (p.source == source && p.remoteId != null) p.remoteId!,
    };
    bool changed = false;
    final List<Playlist> next = <Playlist>[];
    final List<Playlist> merged = <Playlist>[];
    for (final Playlist p in _playlists) {
      if (p.source != source || p.remoteId == null) {
        next.add(p);
        continue;
      }
      known.add(p.remoteId!);
      if (_pushes.containsKey(p.id)) {
        // A push for it is still out, so this answer may be the server's copy
        // from before it landed. Kept as is; the next refresh reconciles it.
        next.add(p);
        continue;
      }
      final ({Playlist playlist, int fetch})? last = _mergedBy[p.id];
      if (last != null && identical(last.playlist, p)) {
        // Last set by another refresh's merge, not by the user since.
        if (last.fetch > fetch) {
          next.add(p); // Its answer is newer than this one: keep it.
          continue;
        }
      } else if (!identical(before[p.id], p)) {
        next.add(p); // Created or edited during the fetch: keep it as is.
        continue;
      }
      if (listing.unread.contains(p.remoteId)) {
        next.add(p); // Listed but unreadable this time: keep it as is.
        continue;
      }
      final RemotePlaylistData? dto = server[p.remoteId];
      if (dto == null) {
        changed = true; // Deleted on the server: drop the mirror.
        continue;
      }
      final Playlist adopted = _adoptServerCopy(p, dto);
      if (!identical(adopted, p)) changed = true;
      next.add(adopted);
      merged.add(adopted);
    }
    // A create still out may already be on the server, and in this answer,
    // under an id nothing here has yet: imported now, it would be a second
    // copy of that playlist, bound to the same server playlist. What is new
    // on the server waits for the next refresh instead.
    final bool creating = _createsOut.any(
      (({PlaylistSource source, int clears}) c) =>
          c.source == source && c.clears == _clearsOf(source),
    );
    for (final RemotePlaylistData dto in remote) {
      if (creating || !known.add(dto.remoteId)) continue;
      // Deleted here, and this answer may have been read before the server
      // delete landed: not new on the server, just not gone from it yet.
      final ({PlaylistSource source, String remoteId}) key =
          (source: source, remoteId: dto.remoteId);
      if (_deletes.containsKey(key)) {
        final int? settled = _deletes[key];
        if (settled == null || fetch <= settled) continue;
      }
      final Playlist imported = Playlist(
        id: _newId(),
        name: dto.name,
        source: source,
        remoteId: dto.remoteId,
        trackIds: dto.trackUris,
        createdAt: _now(),
        updatedAt: _now(),
        syncState: PlaylistSyncState.synced,
      );
      next.add(imported);
      merged.add(imported);
      changed = true;
    }
    if (_refreshesOut > 1) {
      // Another refresh is still out and will ask what set these.
      for (final Playlist p in merged) {
        _mergedBy[p.id] = (playlist: p, fetch: fetch);
      }
    }
    if (changed) _playlists = next;
    return changed;
  }

  /// [p] with the server's name and membership adopted, or [p] itself when it
  /// already matches: an unchanged refresh then rewrites nothing, and
  /// [Playlist.updatedAt] moves only when something did.
  Playlist _adoptServerCopy(Playlist p, RemotePlaylistData dto) {
    if (p.name == dto.name &&
        listEquals(p.trackIds, dto.trackUris) &&
        p.syncState == PlaylistSyncState.synced &&
        p.lastSyncError == null) {
      return p;
    }
    return p.copyWith(
      name: dto.name,
      trackIds: dto.trackUris,
      syncState: PlaylistSyncState.synced,
      lastSyncError: () => null,
      updatedAt: _now(),
    );
  }

  int _clearsOf(PlaylistSource source) => _clears[source] ?? 0;

  @override
  Future<void> clearRemote({PlaylistSource? source}) async {
    // Counted before anything else, so a refresh whose fetch is in flight
    // drops the signed-out account's answer instead of re-importing it.
    for (final RemotePlaylistGateway g in _gateways) {
      if (source == null || g.source == source) {
        _clears[g.source] = _clearsOf(g.source) + 1;
      }
    }
    await _ensureLoaded();
    bool changed = false;
    final List<Playlist> next = <Playlist>[];
    for (final Playlist p in _playlists) {
      if (p.source == PlaylistSource.local ||
          (source != null && p.source != source)) {
        next.add(p);
        continue;
      }
      changed = true;
      // Never reached the server (created while it couldn't be reached): this
      // device holds the only copy, so signing out has nothing to drop it in
      // favour of. It stays, as the device playlist it now is.
      if (p.remoteId == null) {
        next.add(p.copyWith(
          source: PlaylistSource.local,
          syncState: PlaylistSyncState.localOnly,
          lastSyncError: () => null,
          updatedAt: _now(),
        ));
      }
    }
    if (changed) {
      _playlists = next;
      await _persistAndEmit();
    }
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
  ///
  /// Only those: a song the list already held twice stays twice. A server
  /// playlist can (Navidrome lets one), a refresh adopts it as it is, and this
  /// runs on every launch, so collapsing it here would push the shorter list
  /// over the server's with the next edit.
  List<String> _migrateTrackIds(
    Playlist playlist,
    Set<String> catalogUris,
    Map<String, String?> ownerByBareId,
  ) {
    if (playlist.trackIds.isEmpty) return playlist.trackIds;
    bool changed = false;
    // The entry each migrated id was first made from.
    final Map<String, String> firstFrom = <String, String>{};
    final List<String> result = <String>[];
    for (final String id in playlist.trackIds) {
      final String mapped =
          _migrateOneTrackId(id, playlist.source, catalogUris, ownerByBareId);
      if (mapped != id) changed = true;
      if (firstFrom.putIfAbsent(mapped, () => id) == id) {
        result.add(mapped);
      } else {
        changed = true; // two entries the re-key made one: collapsed away
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
    // Signing out while the create is out turns the playlist into a device
    // playlist (see [clearRemote]). What the create says after that is about
    // an account that is gone: neither its failure nor its server id belongs
    // on the device's copy.
    final int clears = _clearsOf(gateway.source);
    final String remoteId;
    try {
      remoteId = await gateway.createRemotePlaylist(
        playlist.name,
        playlist.trackIds,
      );
    } on RemoteSyncException catch (error) {
      if (_clearsOf(gateway.source) != clears) {
        return _byId(playlist.id) ?? playlist;
      }
      return _mutate(
        playlist.id,
        (Playlist p) => p.copyWith(
          syncState: PlaylistSyncState.syncFailed,
          lastSyncError: () => error.message,
        ),
      );
    }
    if (_clearsOf(gateway.source) != clears) {
      return _byId(playlist.id) ?? playlist;
    }
    if (_byId(playlist.id) == null) {
      // Deleted here while the server was still making it. That delete had
      // no server id to send, so it goes now: left there, the playlist would
      // come back with the next refresh.
      final ({PlaylistSource source, String remoteId}) deleted =
          (source: gateway.source, remoteId: remoteId);
      _deletes[deleted] = null;
      try {
        await gateway.deleteRemote(remoteId);
      } on RemoteSyncException catch (_) {
        // Best-effort, like every server delete (see [deletePlaylist]).
      } finally {
        _settleDelete(deleted);
      }
      return playlist;
    }
    return _mutate(
      playlist.id,
      (Playlist p) => p.copyWith(
        remoteId: () => remoteId,
        syncState: PlaylistSyncState.synced,
        lastSyncError: () => null,
      ),
    );
  }

  /// Queues a membership push for a synced playlist behind any push for it
  /// still out (see [_pushInOrder]). A local-only playlist is left alone.
  Future<void> _pushMembership(
    String playlistId, {
    required List<String> added,
    required List<String> removed,
  }) async {
    if (!(_byId(playlistId)?.isRemote ?? false)) return;
    await _pushInOrder(
      playlistId,
      () => _sendMembership(playlistId, added: added, removed: removed),
    );
  }

  /// Runs a best-effort membership change against the server for a synced
  /// playlist, flipping its sync state to synced or syncFailed accordingly. A
  /// local-only playlist (or one not yet created on the server) is left alone.
  ///
  /// [added]/[removed] are the delta; the current full ordered membership is
  /// read fresh when the push goes out and passed too, so a full-replace
  /// provider (Subsonic) has the exact list while an incremental one
  /// (Jellyfin) uses the delta.
  Future<void> _sendMembership(
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
      await _mutate(playlistId, _confirmedPush);
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

  /// Runs [send] once every push queued before it for [playlistId] has
  /// finished, and keeps that playlist out of refresh merges until then.
  ///
  /// Two pushes for one playlist on the wire at once can reach the server in
  /// either order, and a Subsonic push replaces the whole song list: the
  /// older list landing last would quietly undo the newer edit there, as would
  /// the older of two renames. And a refresh answered while a push is still
  /// out may carry the server's copy from before it. Adopting that would drop
  /// the edit on screen, and the next Subsonic push, sending the list as it
  /// then stood, would drop it on the server too.
  Future<T> _pushInOrder<T>(String playlistId, Future<T> Function() send) {
    final Future<void>? earlier = _pushes[playlistId];
    final Future<T> push = earlier == null
        ? send()
        // Only when it ends matters here. Whoever made the earlier edit gets
        // its result, an error included, from their own future.
        : earlier.then((_) {}, onError: (Object _) {}).then((_) => send());
    _pushes[playlistId] = push;
    return push.whenComplete(() {
      if (identical(_pushes[playlistId], push)) _pushes.remove(playlistId);
    });
  }

  /// [p] once a rename or membership push for it has landed: synced, unless
  /// an earlier push for it failed. A push carries only its own change (a
  /// Jellyfin edit sends just what it added or removed, and a Subsonic song
  /// list goes without the name), so it landing says nothing about the one
  /// that didn't. That one stays marked until a refresh reconciles the
  /// playlist with the server, rather than the marker quietly going away and
  /// the next refresh dropping the edit with no sign it never got there.
  ///
  /// Always a new object, though, even when nothing on it changes: a refresh
  /// that read the server before this push landed tells that its answer is
  /// older only by identity (see [_mergeRemote]), and by then the push has
  /// left [_pushes]. Handing back [p] itself let that answer undo the edit.
  static Playlist _confirmedPush(Playlist p) {
    if (p.syncState == PlaylistSyncState.syncFailed) return p.copyWith();
    return p.copyWith(
      syncState: PlaylistSyncState.synced,
      lastSyncError: () => null,
    );
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
    try {
      await _store.save(_playlists);
    } on LocalStoreWriteException catch (error) {
      StabilityDiagnostics.localStoreWriteFailure(error.area.name);
      rethrow;
    }
    _emit();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(_snapshot());
  }

  Future<void> dispose() => _changes.close();
}
