import 'dart:async';

import '../../core/models/track.dart';
import '../../core/repositories/favorites_repository.dart';
import '../../core/repositories/favorites_store.dart';
import '../../core/repositories/local_store_write_exception.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/repositories/remote_sync_result.dart';
import '../../core/repositories/track_identity_reassignable.dart';
import '../../core/services/stability_diagnostics.dart';
import '../../core/sources/music_provider.dart';

/// The app's [FavoritesRepository]: an optimistic local mirror with best-effort
/// server sync layered on top, across any number of providers.
///
/// Favourites live in a [FavoritesStore] split into device-local uris (local
/// tracks) and remote uris (server-mirrored — Jellyfin, Subsonic/Navidrome, …),
/// keyed by the provider-namespaced [Track.uri] so a heart on `jellyfin:101`
/// can't collide with `subsonic:101`. A toggle is saved, then made current and
/// emitted; for a remote track whose provider is connected it is then pushed to
/// that server best-effort through the provider's [RemoteFavoritesGateway]. A
/// toggle the disk refuses changes nothing and throws (see [_write]).
///
/// Reliability of the heart: a push that fails (offline, a transient server
/// error, or the provider not connected yet) is **not** dropped — the intended
/// state is recorded in [_pendingWrites], saved with the favourites so it
/// outlives a restart, and re-attempted on the next [refreshFromRemote], and
/// until it lands the local heart is preserved even
/// though the server's starred list doesn't yet contain it. That closes the
/// "heart it, then a refresh silently un-hearts it because the server never got
/// the star" gap: the repository never pretends a failed write succeeded, and it
/// never reverts an un-synced local intent. [refreshFromRemote] otherwise adopts
/// each connected server's starred set as the truth for *its* scheme, leaving
/// local-track favourites and other providers' hearts alone, as well as any heart
/// toggled while the refresh was waiting on the server (the answer predates it).
///
/// Security: only non-secret track/item ids are stored or sent. Sessions (with
/// their tokens) live behind the gateways and are never logged or persisted
/// here. Local-track favourites are never sent anywhere.
class SyncedFavoritesRepository
    implements FavoritesRepository, TrackIdentityReassignable {
  SyncedFavoritesRepository({
    required FavoritesStore store,
    List<RemoteFavoritesGateway> gateways = const <RemoteFavoritesGateway>[],
  })  : _store = store,
        _gateways = gateways;

  final FavoritesStore _store;

  /// The per-provider server seams. Empty for a purely local setup (tests, the
  /// data-layer default); the composition root supplies one per remote provider.
  final List<RemoteFavoritesGateway> _gateways;

  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();

  /// Remote heart toggles whose server push hasn't landed yet (uri → desired
  /// favourite state), so a failed/queued write is retried on the next refresh
  /// and isn't reverted by the server's (stale) starred list in the meantime.
  final Map<String, bool> _pendingWrites = <String, bool>{};

  /// One set per running [refreshFromRemote], collecting the remote uris
  /// hearted or un-hearted since it began. Its servers' answers predate those
  /// toggles, so they keep their local state rather than the answer's.
  final List<Set<String>> _toggledDuringRefresh = <Set<String>>[];

  /// How many times each provider's hearts have been cleared (its sign-out),
  /// by uri scheme. A refresh notes the counts before asking the servers and
  /// discards a provider's answer if its count moved meanwhile.
  final Map<String, int> _clears = <String, int>{};

  /// The providers signed out of (their hearts cleared) and not seen signed
  /// in since, by uri scheme. Their songs stay in the library, so they can
  /// still be hearted, but such a heart belongs to no account: it is kept as
  /// it is and never queued for a push, since whoever signs in next (another
  /// person, another server) did not make it, and that account's own starred
  /// list replaces the provider's hearts on its first refresh.
  final Set<String> _signedOut = <String>{};

  /// How many times each remote uri has been toggled. A push notes the number
  /// of the toggle it carries, so when it comes back it can tell whether a
  /// newer toggle was made while it was out.
  final Map<String, int> _toggles = <String, int>{};

  FavoritesData _data = FavoritesData.empty;
  bool _loaded = false;

  /// The end of the queue every change to [_data] and [_pendingWrites] waits
  /// in. See [_inTurn].
  Future<void> _queue = Future<void>.value();

  /// How many remote heart writes are still waiting to reach a server (failed or
  /// queued while offline). Exposed for diagnostics/tests; a non-zero value means
  /// the last toggle(s) are being retried, not silently lost.
  int get pendingRemoteWriteCount => _pendingWrites.length;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _data = await _store.load();
    _pendingWrites.addAll(_data.pendingWrites);
    _loaded = true;
  }

  /// Runs [change] once every change queued before it has finished, so each
  /// one starts from what the last one left and nothing else changes the
  /// favourites between its read and its save.
  Future<T> _inTurn<T>(Future<T> Function() change) {
    final Future<T> run = _queue.then((_) => change());
    _queue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// Saves [next] with the [pending] writes and only then makes them current.
  /// Called in turn (see [_inTurn]).
  ///
  /// The pending writes are saved with the favourites, so a heart whose push
  /// never landed is retried after a restart rather than undone by the first
  /// refresh. A save the disk refuses leaves memory, the stream and the disk
  /// all as they were: the change is not half there, where a later save that
  /// works would write it after all (#808).
  Future<void> _write(FavoritesData next, Map<String, bool> pending) async {
    try {
      await _store.save(
        next.copyWith(pendingWrites: Map<String, bool>.of(pending)),
      );
    } on LocalStoreWriteException catch (error) {
      StabilityDiagnostics.localStoreWriteFailure(error.area.name);
      rethrow;
    }
    _commit(next, pending);
  }

  void _commit(FavoritesData next, Map<String, bool> pending) {
    _data = next;
    if (!identical(pending, _pendingWrites)) {
      _pendingWrites
        ..clear()
        ..addAll(pending);
    }
  }

  Set<String> get _all => <String>{..._data.localIds, ..._data.remoteIds};

  @override
  Stream<Set<String>> get favoritesStream async* {
    await _ensureLoaded();
    yield _all;
    yield* _changes.stream;
  }

  @override
  bool isFavorite(String trackUri) =>
      _data.localIds.contains(trackUri) || _data.remoteIds.contains(trackUri);

  @override
  Future<void> setFavorite(Track track, bool favorite) async {
    await _ensureLoaded();
    // Identity is the provider-namespaced uri so two providers' same-id tracks
    // stay distinct; the gateway maps it back to the bare id for the request.
    final String key = track.uri;
    final bool remote = _isRemoteUri(key);
    final RemoteFavoritesGateway? gateway = remote ? _gatewayForUri(key) : null;
    // Throws, having changed nothing, when the disk refuses the save: the
    // heart isn't shown, kept, or pushed (#808).
    final int toggle = await _inTurn(() async {
      if (!remote) {
        await _write(
          _data.copyWith(localIds: _withMember(_data.localIds, key, favorite)),
          _pendingWrites,
        );
        _emit();
        return 0;
      }
      final Map<String, bool> pending = Map<String, bool>.of(_pendingWrites);
      // Pending from this moment until a push of it is confirmed, so a
      // refresh that lands first keeps it rather than adopting an answer that
      // predates it, and a push that never comes back leaves it to retry.
      if (gateway != null && _hasAccount(gateway)) pending[key] = favorite;
      await _write(
        _data.copyWith(remoteIds: _withMember(_data.remoteIds, key, favorite)),
        pending,
      );
      for (final Set<String> toggled in _toggledDuringRefresh) {
        toggled.add(key);
      }
      final int toggle = (_toggles[key] ?? 0) + 1;
      _toggles[key] = toggle;
      _emit();
      return toggle;
    });

    // Push to the owning provider's server best-effort. A failure (or the
    // provider not being connected yet) leaves the write pending, retried on
    // the next refresh: the optimistic local state stands and is never
    // silently lost or reverted. Never throws.
    if (gateway != null && gateway.isConnected) {
      final int clearsBefore = _clearsOf(gateway.uriScheme);
      bool landed;
      try {
        await gateway.pushFavorite(key, favorite);
        landed = true;
      } catch (_) {
        landed = false;
      }
      await _settle(
        key,
        favorite,
        landed: landed,
        toggle: toggle,
        clearsBefore: clearsBefore,
        scheme: gateway.uriScheme,
      );
    }
  }

  static Set<String> _withMember(Set<String> ids, String key, bool member) {
    final Set<String> next = <String>{...ids};
    if (member) {
      next.add(key);
    } else {
      next.remove(key);
    }
    return next;
  }

  /// Settles [key]'s pending write once the push of toggle number [toggle]
  /// ([favorite]) has come back, [landed] or not, in turn with the other
  /// changes. Saved best effort: a stale record on disk only means one write is
  /// pushed again, so a refused save just leaves it pending.
  Future<void> _settle(
    String key,
    bool favorite, {
    required bool landed,
    required int? toggle,
    required int clearsBefore,
    required String scheme,
  }) =>
      _inTurn(() async {
        final Map<String, bool> pending = Map<String, bool>.of(_pendingWrites);
        if (!_settlePush(
          pending,
          key,
          favorite,
          landed: landed,
          toggle: toggle,
          clearsBefore: clearsBefore,
          scheme: scheme,
        )) {
          return;
        }
        try {
          await _write(_data, pending);
        } catch (_) {
          // Never worth failing the heart over; see above.
        }
      });

  /// Works out in [pending] how [key]'s write settles once the push of toggle
  /// number [toggle] ([favorite]) has come back, [landed] or not.
  ///
  /// Only the newest toggle decides. Taps are quicker than a server, so an
  /// older push can come back after a newer one, or fail after it landed:
  ///  - the newest push landing confirms the write; failing leaves it pending;
  ///  - an older push coming back after a newer toggle may have left the
  ///    server on its older value, whichever order the two landed in, so the
  ///    newest intent stays pending and is sent again on the next refresh;
  ///  - a push from an account that signed out meanwhile settles nothing: its
  ///    writes were dropped with it, and must not be queued for the next one.
  ///
  /// Returns whether [pending] changed, so the caller saves it.
  bool _settlePush(
    Map<String, bool> pending,
    String key,
    bool favorite, {
    required bool landed,
    required int? toggle,
    required int clearsBefore,
    required String scheme,
  }) {
    if (_clearsOf(scheme) != clearsBefore) return false;
    if (_toggles[key] != toggle) {
      final bool intended = _data.remoteIds.contains(key);
      if (pending[key] == intended) return false;
      pending[key] = intended;
      return true;
    }
    if (landed && pending[key] == favorite) {
      pending.remove(key);
      return true;
    }
    return false;
  }

  @override
  Future<FavoritesSyncResult> refreshFromRemote({
    String? providerScheme,
  }) async {
    await _ensureLoaded();
    final List<RemoteFavoritesGateway> connected = <RemoteFavoritesGateway>[
      for (final g in _gateways)
        if (g.isConnected &&
            (providerScheme == null || g.uriScheme == providerScheme))
          g
    ];
    if (connected.isEmpty) {
      return const FavoritesSyncResult.notConfigured();
    }
    for (final RemoteFavoritesGateway g in connected) {
      _signedOut.remove(g.uriScheme);
    }

    // The user keeps hearting (and may sign out) while the requests below are
    // out, so nothing read from [_data] before an await is written back after
    // it. The servers are asked first; their answers are then adopted into the
    // favourites as they are when the answers land, in turn with the toggles.
    final Map<String, int> clears = <String, int>{
      for (final RemoteFavoritesGateway g in connected)
        g.uriScheme: _clearsOf(g.uriScheme),
    };
    final Set<String> toggled = <String>{};
    _toggledDuringRefresh.add(toggled);
    try {
      final Map<RemoteFavoritesGateway, Set<String>> fetched =
          <RemoteFavoritesGateway, Set<String>>{};
      int failures = 0;
      for (final RemoteFavoritesGateway gateway in connected) {
        // 1) Re-attempt this provider's pending writes first, so a heart that
        //    failed to push earlier lands before we adopt the server's list (and
        //    isn't reverted by a list that predates it). A still-failing write
        //    stays pending for the next refresh.
        for (final String uri in _pendingForScheme(gateway.uriScheme)) {
          // Read now, not from the list above: while an earlier push was out, a
          // sign-out may have dropped this write or a toggle replaced it.
          final bool? favorite = _pendingWrites[uri];
          if (favorite == null) continue;
          // A push like any other: a toggle made while it is out pushes too,
          // and can reach the server first. So it settles against the newest
          // toggle the way a tap's push does, rather than only clearing the
          // value it sent, which would leave the server on this older value
          // with nothing pending to put it right.
          // Null for a write loaded from disk and not toggled since: then
          // nothing newer can have replaced it.
          final int? toggle = _toggles[uri];
          final int clearsBefore = _clearsOf(gateway.uriScheme);
          bool landed;
          try {
            await gateway.pushFavorite(uri, favorite);
            landed = true;
          } on RemoteSyncException {
            // Kept pending; tried again on the next refresh.
            landed = false;
          }
          await _settle(
            uri,
            favorite,
            landed: landed,
            toggle: toggle,
            clearsBefore: clearsBefore,
            scheme: gateway.uriScheme,
          );
        }

        try {
          fetched[gateway] = await gateway.fetchFavoriteUris();
        } on RemoteSyncException {
          // Offline or transient for this provider: keep its subset, try the
          // rest.
          failures++;
        }
      }

      // 2) Adopt the answers, in turn: nothing else changes the favourites
      //    between reading them here and saving the result.
      return await _inTurn(() => _adopt(fetched, clears, toggled, failures));
    } finally {
      _toggledDuringRefresh.remove(toggled);
    }
  }

  /// Folds the servers' [fetched] answers into the favourites as they are now.
  /// Called in turn; see [refreshFromRemote].
  Future<FavoritesSyncResult> _adopt(
    Map<RemoteFavoritesGateway, Set<String>> fetched,
    Map<String, int> clears,
    Set<String> toggled,
    int failures,
  ) async {
    Set<String> remoteIds = <String>{..._data.remoteIds};
    int total = 0;
    int applied = 0;
    for (final MapEntry<RemoteFavoritesGateway, Set<String>> entry
        in fetched.entries) {
      final String scheme = entry.key.uriScheme;
      // Signed out (or cleared) while the fetch was out: the answer is that
      // account's, which is gone. A gateway can still look connected on a
      // session it captured earlier; the clear count is what says so.
      if (!entry.key.isConnected || _clearsOf(scheme) != clears[scheme]) {
        continue;
      }
      applied++;
      total += entry.value.length;
      // Replace only this provider's scheme subset with the server truth,
      // except hearts toggled since the refresh began: the answer predates
      // them, so they keep their local state…
      remoteIds = <String>{
        for (final String uri in remoteIds)
          if (!uri.startsWith(scheme) || toggled.contains(uri)) uri,
        for (final String uri in entry.value)
          if (!toggled.contains(uri)) uri,
      };
      // …then overlay any writes still pending for this scheme, so an
      // un-landed local heart isn't dropped just because the server list
      // doesn't have it yet (non-destructive: local intent wins until it's
      // confirmed).
      for (final String uri in _pendingForScheme(scheme)) {
        if (_pendingWrites[uri]!) {
          remoteIds.add(uri);
        } else {
          remoteIds.remove(uri);
        }
      }
    }

    // Skip the emit/save when nothing changed, to avoid churn — but still
    // report the (unchanged) count as a successful sync.
    final bool unchanged = remoteIds.length == _data.remoteIds.length &&
        remoteIds.containsAll(_data.remoteIds);
    if (!unchanged) {
      // A refused save throws, and the refresh reports it failed, with the
      // favourites left as they were.
      await _write(_data.copyWith(remoteIds: remoteIds), _pendingWrites);
      _emit();
    }
    if (applied == 0) {
      return failures > 0
          ? const FavoritesSyncResult.failed()
          : const FavoritesSyncResult.notConfigured();
    }
    return FavoritesSyncResult.synced(total);
  }

  int _clearsOf(String scheme) => _clears[scheme] ?? 0;

  /// Whether a heart on [gateway]'s songs is someone's to push: an account is
  /// signed in, or one may still be coming (nothing was signed out since this
  /// process started, as when a saved sign-in is still loading).
  bool _hasAccount(RemoteFavoritesGateway gateway) {
    if (gateway.isConnected) _signedOut.remove(gateway.uriScheme);
    return gateway.isConnected || !_signedOut.contains(gateway.uriScheme);
  }

  @override
  Future<void> clearRemote({String? providerScheme}) async {
    // Counted before anything else, so a refresh whose fetch is out drops the
    // signed-out account's answer instead of adopting it.
    for (final RemoteFavoritesGateway g in _gateways) {
      if (providerScheme == null || g.uriScheme == providerScheme) {
        _clears[g.uriScheme] = _clearsOf(g.uriScheme) + 1;
        _signedOut.add(g.uriScheme);
      }
    }
    await _ensureLoaded();
    await _inTurn(() async {
      // Drop this provider's queued writes too — its session is going away, so
      // there is nothing left to reconcile them against, and whoever signs in
      // next did not make them. Saved even when no heart changes, or they
      // would come back from disk on the next launch.
      final Map<String, bool> pending = Map<String, bool>.of(_pendingWrites)
        ..removeWhere((String uri, bool _) =>
            providerScheme == null || uri.startsWith(providerScheme));
      final bool pendingDropped = pending.length != _pendingWrites.length;
      final Set<String> next = providerScheme == null
          ? const <String>{}
          : <String>{
              for (final String uri in _data.remoteIds)
                if (!uri.startsWith(providerScheme)) uri,
            };
      final bool heartsDropped = next.length != _data.remoteIds.length;
      if (!heartsDropped && !pendingDropped) return;
      final FavoritesData cleared = _data.copyWith(remoteIds: next);
      try {
        await _write(cleared, pending);
      } finally {
        // Unlike a heart, this stands even when the disk refuses it: the
        // account is signed out either way, and keeping its hearts and queued
        // writes would show them, and push them, for whoever signs in next.
        // The next save that lands writes the clear too.
        _commit(cleared, pending);
        if (heartsDropped) _emit();
      }
    });
  }

  /// Carries a moved local file's heart to its new path.
  ///
  /// Only the device-local set takes part. A local track's uri is its
  /// filesystem path, so it can never be a `scheme:`-namespaced remote uri, and
  /// a caller handing us one is asking for something a *server* owns. It is refused
  /// rather than quietly rewritten, since no server was told about it and the
  /// next refresh would revert it anyway. Nothing is pushed anywhere: local
  /// hearts never leave the device.
  @override
  Future<void> reassignTrack({
    required String fromUri,
    required String toUri,
  }) async {
    if (fromUri == toUri) return;
    if (_isRemoteUri(fromUri) || _isRemoteUri(toUri)) return;
    try {
      await _ensureLoaded();
      await _inTurn(() async {
        if (!_data.localIds.contains(fromUri)) return;
        await _write(
          _data.copyWith(
            localIds: <String>{..._data.localIds}
              ..remove(fromUri)
              ..add(toUri),
          ),
          _pendingWrites,
        );
        _emit();
      });
    } catch (_) {
      // A store that cannot be written right now leaves the heart where it is
      // rather than failing the scan that asked; the next scan tries again.
    }
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(_all);
  }

  /// The pending-write uris that belong to [scheme], as a stable snapshot (so a
  /// caller can safely remove entries from [_pendingWrites] while iterating).
  List<String> _pendingForScheme(String scheme) => <String>[
        for (final String uri in _pendingWrites.keys)
          if (uri.startsWith(scheme)) uri,
      ];

  /// Whether [trackUri] belongs to a remote provider (any known `scheme:` id) —
  /// so it lives in the server-owned set — rather than an on-device track.
  static bool _isRemoteUri(String trackUri) =>
      MusicProviders.bareRemoteIdForTrackUri(trackUri) != null;

  /// The gateway that owns [trackUri] by its scheme, or `null` when no connected
  /// provider handles it.
  RemoteFavoritesGateway? _gatewayForUri(String trackUri) {
    for (final RemoteFavoritesGateway gateway in _gateways) {
      if (trackUri.startsWith(gateway.uriScheme)) return gateway;
    }
    return null;
  }

  Future<void> dispose() => _changes.close();
}
