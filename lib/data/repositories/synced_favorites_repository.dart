import 'dart:async';

import '../../core/models/track.dart';
import '../../core/repositories/favorites_repository.dart';
import '../../core/repositories/favorites_store.dart';
import '../../core/repositories/remote_sync_gateway.dart';
import '../../core/repositories/remote_sync_result.dart';
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
/// local-track favourites and other providers' hearts alone.
///
/// Security: only non-secret track/item ids are stored or sent. Sessions (with
/// their tokens) live behind the gateways and are never logged or persisted
/// here. Local-track favourites are never sent anywhere.
class SyncedFavoritesRepository implements FavoritesRepository {
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
    if (remote) {
      final Set<String> ids = <String>{..._data.remoteIds};
      if (favorite) {
        ids.add(key);
      } else {
        ids.remove(key);
      }
      _data = _data.copyWith(remoteIds: ids);
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
    // provider not being connected yet) is recorded as a pending write and
    // retried on the next refresh — the optimistic local state stands and is
    // never silently lost or reverted. Never throws.
    if (remote) {
      final RemoteFavoritesGateway? gateway = _gatewayForUri(key);
      if (gateway != null) {
        if (gateway.isConnected) {
          try {
            await gateway.pushFavorite(key, favorite);
            _pendingWrites.remove(key); // confirmed on the server
          } catch (_) {
            _pendingWrites[key] = favorite; // failed: retry on next refresh
          }
        } else {
          _pendingWrites[key] = favorite; // queued until the provider connects
        }
      }
    }
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

    Set<String> remoteIds = <String>{..._data.remoteIds};
    int total = 0;
    int successCount = 0;
    for (final RemoteFavoritesGateway gateway in connected) {
      final String scheme = gateway.uriScheme;

      // 1) Re-attempt this provider's pending writes first, so a heart that
      //    failed to push earlier lands before we adopt the server's list (and
      //    isn't reverted by a list that predates it). A still-failing write
      //    stays pending for the next refresh.
      for (final String uri in _pendingForScheme(scheme)) {
        try {
          await gateway.pushFavorite(uri, _pendingWrites[uri]!);
          _pendingWrites.remove(uri);
        } on RemoteSyncException {
          // Keep it pending; try again next refresh.
        }
      }

      final Set<String> serverUris;
      try {
        serverUris = await gateway.fetchFavoriteUris();
      } on RemoteSyncException {
        // Offline or transient for this provider: keep its subset, try the rest.
        continue;
      }
      successCount++;
      total += serverUris.length;
      // Replace only this provider's scheme subset with the server truth…
      remoteIds = <String>{
        for (final String uri in remoteIds)
          if (!uri.startsWith(scheme)) uri,
        ...serverUris,
      };
      // …then overlay any writes still pending for this scheme, so an un-landed
      // local heart isn't dropped just because the server list doesn't have it
      // yet (non-destructive: local intent wins until it's confirmed).
      for (final String uri in _pendingForScheme(scheme)) {
        if (_pendingWrites[uri]!) {
          remoteIds.add(uri);
        } else {
          remoteIds.remove(uri);
        }
      }
    }

    // Skip the emit/save when nothing changed, to avoid churn — but still report
    // the (unchanged) count as a successful sync.
    final bool unchanged = remoteIds.length == _data.remoteIds.length &&
        remoteIds.containsAll(_data.remoteIds);
    if (!unchanged) {
      _data = _data.copyWith(remoteIds: remoteIds);
      _emit();
      await _store.save(_data);
    }
    if (successCount == 0) return const FavoritesSyncResult.failed();
    return FavoritesSyncResult.synced(total);
  }

  @override
  Future<void> clearRemote({String? providerScheme}) async {
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
