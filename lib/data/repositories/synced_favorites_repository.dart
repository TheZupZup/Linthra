import 'dart:async';

import '../../core/models/track.dart';
import '../../core/repositories/favorites_repository.dart';
import '../../core/repositories/favorites_store.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/repositories/remote_sync_result.dart';
import '../../core/repositories/track_identity_reassignable.dart';
import '../../core/sources/music_provider.dart';

/// The app's [FavoritesRepository]: an optimistic local mirror with best-effort
/// server sync layered on top, across any number of providers.
///
/// Favourites live in a [FavoritesStore] split into device-local uris (local
/// tracks) and remote uris (server-mirrored — Jellyfin, Subsonic/Navidrome, …),
/// keyed by the provider-namespaced [Track.uri] so a heart on `jellyfin:101`
/// can't collide with `subsonic:101`. A toggle updates the right set
/// immediately, emits, and persists; for a remote track whose provider is
/// connected it then pushes to that server best-effort through the provider's
/// [RemoteFavoritesGateway].
///
/// Reliability of the heart: a push that fails (offline, a transient server
/// error, or the provider not connected yet) is **not** dropped — the intended
/// state is recorded in [_pendingWrites] and re-attempted on the next
/// [refreshFromRemote], and until it lands the local heart is preserved even
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

  /// How many times each remote uri has been toggled. A push notes the number
  /// of the toggle it carries, so when it comes back it can tell whether a
  /// newer toggle was made while it was out.
  final Map<String, int> _toggles = <String, int>{};

  FavoritesData _data = FavoritesData.empty;
  bool _loaded = false;

  /// How many remote heart writes are still waiting to reach a server (failed or
  /// queued while offline). Exposed for diagnostics/tests; a non-zero value means
  /// the last toggle(s) are being retried, not silently lost.
  int get pendingRemoteWriteCount => _pendingWrites.length;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _data = await _store.load();
    _loaded = true;
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
    final int toggle = (_toggles[key] ?? 0) + 1;
    if (remote) {
      final Set<String> ids = <String>{..._data.remoteIds};
      if (favorite) {
        ids.add(key);
      } else {
        ids.remove(key);
      }
      _data = _data.copyWith(remoteIds: ids);
      for (final Set<String> toggled in _toggledDuringRefresh) {
        toggled.add(key);
      }
      _toggles[key] = toggle;
      // Pending from this moment until a push of it is confirmed, so a
      // refresh that lands first keeps it rather than adopting an answer that
      // predates it, and a push that never comes back leaves it to retry.
      if (gateway != null) _pendingWrites[key] = favorite;
    } else {
      final Set<String> ids = <String>{..._data.localIds};
      if (favorite) {
        ids.add(key);
      } else {
        ids.remove(key);
      }
      _data = _data.copyWith(localIds: ids);
    }
    _emit();
    await _store.save(_data);

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
      _settlePush(
        key,
        favorite,
        landed: landed,
        toggle: toggle,
        clearsBefore: clearsBefore,
        scheme: gateway.uriScheme,
      );
    }
  }

  /// Settles [key]'s pending write once the push of toggle number [toggle]
  /// ([favorite]) has come back, [landed] or not.
  ///
  /// Only the newest toggle decides. Taps are quicker than a server, so an
  /// older push can come back after a newer one, or fail after it landed:
  ///  - the newest push landing confirms the write; failing leaves it pending;
  ///  - an older push coming back after a newer toggle may have left the
  ///    server on its older value, whichever order the two landed in, so the
  ///    newest intent stays pending and is sent again on the next refresh;
  ///  - a push from an account that signed out meanwhile settles nothing: its
  ///    writes were dropped with it, and must not be queued for the next one.
  void _settlePush(
    String key,
    bool favorite, {
    required bool landed,
    required int toggle,
    required int clearsBefore,
    required String scheme,
  }) {
    if (_clearsOf(scheme) != clearsBefore) return;
    if (_toggles[key] != toggle) {
      _pendingWrites[key] = _data.remoteIds.contains(key);
      return;
    }
    if (landed && _pendingWrites[key] == favorite) _pendingWrites.remove(key);
  }

  @override
  Future<FavoritesSyncResult> refreshFromRemote() async {
    await _ensureLoaded();
    final List<RemoteFavoritesGateway> connected = <RemoteFavoritesGateway>[
      for (final g in _gateways)
        if (g.isConnected) g
    ];
    if (connected.isEmpty) {
      return const FavoritesSyncResult.notConfigured();
    }

    // The user keeps hearting (and may sign out) while the requests below are
    // out, so nothing read from [_data] before an await is written back after
    // it. The servers are asked first; their answers are then adopted into the
    // favourites as they are when the answers land, in one synchronous step.
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
          try {
            await gateway.pushFavorite(uri, favorite);
            // A toggle made while this push was out is a newer intent that
            // still has to land, so only the value just pushed is cleared.
            if (_pendingWrites[uri] == favorite) _pendingWrites.remove(uri);
          } on RemoteSyncException {
            // Keep it pending; try again next refresh.
          }
        }

        try {
          fetched[gateway] = await gateway.fetchFavoriteUris();
        } on RemoteSyncException {
          // Offline or transient for this provider: keep its subset, try the
          // rest.
          failures++;
        }
      }

      // 2) Adopt the answers. From here to the assignment there is no await.
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
        _data = _data.copyWith(remoteIds: remoteIds);
        _emit();
        await _store.save(_data);
      }
      if (applied == 0) {
        return failures > 0
            ? const FavoritesSyncResult.failed()
            : const FavoritesSyncResult.notConfigured();
      }
      return FavoritesSyncResult.synced(total);
    } finally {
      _toggledDuringRefresh.remove(toggled);
    }
  }

  int _clearsOf(String scheme) => _clears[scheme] ?? 0;

  @override
  Future<void> clearRemote({String? providerScheme}) async {
    // Counted before anything else, so a refresh whose fetch is out drops the
    // signed-out account's answer instead of adopting it.
    for (final RemoteFavoritesGateway g in _gateways) {
      if (providerScheme == null || g.uriScheme == providerScheme) {
        _clears[g.uriScheme] = _clearsOf(g.uriScheme) + 1;
      }
    }
    await _ensureLoaded();
    // Drop this provider's queued writes too — its session is going away, so
    // there is nothing left to reconcile them against.
    _pendingWrites.removeWhere((String uri, bool _) =>
        providerScheme == null || uri.startsWith(providerScheme));
    if (_data.remoteIds.isEmpty) return;
    final Set<String> next = providerScheme == null
        ? const <String>{}
        : <String>{
            for (final String uri in _data.remoteIds)
              if (!uri.startsWith(providerScheme)) uri,
          };
    if (next.length == _data.remoteIds.length) return; // nothing to drop
    _data = _data.copyWith(remoteIds: next);
    _emit();
    await _store.save(_data);
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
      if (!_data.localIds.contains(fromUri)) return;
      _data = _data.copyWith(
        localIds: <String>{..._data.localIds}
          ..remove(fromUri)
          ..add(toUri),
      );
      _emit();
      await _store.save(_data);
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
