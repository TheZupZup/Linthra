import 'dart:async';

import '../../core/models/jellyfin_session.dart';
import '../../core/models/track.dart';
import '../../core/repositories/favorites_repository.dart';
import '../../core/repositories/favorites_store.dart';
import '../../core/repositories/remote_sync_result.dart';
import '../../core/sources/jellyfin/jellyfin_client.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';

/// The app's [FavoritesRepository]: an optimistic local mirror with Jellyfin
/// sync layered on top.
///
/// Favourites live in a [FavoritesStore] split into device-local uris (local
/// tracks) and remote uris (Jellyfin), keyed by the provider-namespaced
/// [Track.uri] so a favourite on `jellyfin:101` can't collide with
/// `subsonic:101`. A toggle updates the right set immediately, emits, and
/// persists; for a Jellyfin track while signed in it then pushes to the server
/// best-effort using the bare item id. [refreshFromRemote] adopts the server's
/// set (namespaced back to jellyfin: uris) as the remote truth, leaving
/// local-track favourites alone, so favourites set on another client show up
/// here.
///
/// Security: only non-secret track/item ids are stored or sent. The session
/// (with its token) is read lazily through [_session] for the request header —
/// never logged or persisted here. Local-track favourites are never sent
/// anywhere.
class JellyfinSyncedFavoritesRepository implements FavoritesRepository {
  JellyfinSyncedFavoritesRepository({
    required FavoritesStore store,
    JellyfinClient? client,
    JellyfinSession? Function()? session,
  })  : _store = store,
        _client = client,
        _session = session;

  final FavoritesStore _store;

  /// The Jellyfin HTTP seam, or `null` when favourites are local-only (tests,
  /// the data-layer default). Read lazily alongside [_session].
  final JellyfinClient? _client;

  /// Supplies the live signed-in session, or `null` when not connected. Read at
  /// call time so signing in/out is picked up without rebuilding the repository.
  final JellyfinSession? Function()? _session;

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
    final bool remote = _isRemote(track);
    // Identity is the provider-namespaced uri so two providers' same-id tracks
    // stay distinct; the server push below still uses the bare item id.
    final String key = track.uri;
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

    // Push to the server best-effort; a failure keeps the optimistic local
    // state, which the next refresh reconciles. Never throws out of here.
    if (remote) {
      final JellyfinClient? client = _client;
      final JellyfinSession? session = _session?.call();
      if (client != null && session != null) {
        try {
          await client.setFavorite(session, track.id, favorite: favorite);
        } catch (_) {
          // Ignore: optimistic local state stands; refresh reconciles later.
        }
      }
    }
  }

  @override
  Future<FavoritesSyncResult> refreshFromRemote() async {
    await _ensureLoaded();
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) {
      return const FavoritesSyncResult.notConfigured();
    }
    try {
      final Set<String> serverIds = await client.fetchFavoriteIds(session);
      // The server speaks bare item ids; namespace them to the jellyfin: uri the
      // store and UI key on, so a server favourite matches its catalog track.
      final Set<String> serverUris = <String>{
        for (final String id in serverIds)
          '${JellyfinTrackMapper.uriScheme}$id',
      };
      // Skip the emit/save when nothing actually changed, to avoid churn — but
      // still report the (unchanged) count as a successful sync.
      final bool unchanged = serverUris.length == _data.remoteIds.length &&
          serverUris.containsAll(_data.remoteIds);
      if (!unchanged) {
        _data = _data.copyWith(remoteIds: serverUris);
        _emit();
        await _store.save(_data);
      }
      return FavoritesSyncResult.synced(serverUris.length);
    } catch (_) {
      // Offline or transient: keep what we have and report a friendly failure.
      return const FavoritesSyncResult.failed();
    }
  }

  @override
  Future<void> clearRemote() async {
    await _ensureLoaded();
    if (_data.remoteIds.isEmpty) return;
    _data = _data.copyWith(remoteIds: const <String>{});
    _emit();
    await _store.save(_data);
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(_all);
  }

  static bool _isRemote(Track track) =>
      track.uri.startsWith(JellyfinTrackMapper.uriScheme);

  Future<void> dispose() => _changes.close();
}
