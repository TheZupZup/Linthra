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
/// [RemoteFavoritesGateway]. [refreshFromRemote] adopts each connected server's
/// starred set as the truth for *its* scheme, leaving local-track favourites and
/// other providers' hearts alone.
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

  FavoritesData _data = FavoritesData.empty;
  bool _loaded = false;

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

    // Push to the owning provider's server best-effort; a failure keeps the
    // optimistic local state, which the next refresh reconciles. Never throws.
    if (remote) {
      final RemoteFavoritesGateway? gateway = _gatewayForUri(key);
      if (gateway != null && gateway.isConnected) {
        try {
          await gateway.pushFavorite(key, favorite);
        } catch (_) {
          // Ignore: optimistic local state stands; refresh reconciles later.
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
      final Set<String> serverUris;
      try {
        serverUris = await gateway.fetchFavoriteUris();
      } on RemoteSyncException {
        // Offline or transient for this provider: keep its subset, try the rest.
        continue;
      }
      successCount++;
      total += serverUris.length;
      // Replace only this provider's scheme subset; leave the others alone.
      final String scheme = gateway.uriScheme;
      remoteIds = <String>{
        for (final String uri in remoteIds)
          if (!uri.startsWith(scheme)) uri,
        ...serverUris,
      };
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
