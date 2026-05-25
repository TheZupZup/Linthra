import 'dart:async';

import '../../core/models/jellyfin_session.dart';
import '../../core/models/track.dart';
import '../../core/repositories/favorites_repository.dart';
import '../../core/repositories/favorites_store.dart';
import '../../core/sources/jellyfin/jellyfin_client.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';

/// The app's [FavoritesRepository]: an optimistic local mirror with Jellyfin
/// sync layered on top.
///
/// Favourites live in a [FavoritesStore] split into device-local ids (local
/// tracks) and remote ids (Jellyfin item ids). A toggle updates the right set
/// immediately, emits, and persists; for a Jellyfin track while signed in it
/// then pushes to the server best-effort. [refreshFromRemote] adopts the
/// server's set as the remote truth, leaving local-track favourites alone, so
/// favourites set on another client show up here.
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
  bool isFavorite(String trackId) =>
      _data.localIds.contains(trackId) || _data.remoteIds.contains(trackId);

  @override
  Future<void> setFavorite(Track track, bool favorite) async {
    await _ensureLoaded();
    final bool remote = _isRemote(track);
    if (remote) {
      final Set<String> ids = <String>{..._data.remoteIds};
      if (favorite) {
        ids.add(track.id);
      } else {
        ids.remove(track.id);
      }
      _data = _data.copyWith(remoteIds: ids);
    } else {
      final Set<String> ids = <String>{..._data.localIds};
      if (favorite) {
        ids.add(track.id);
      } else {
        ids.remove(track.id);
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
  Future<void> refreshFromRemote() async {
    await _ensureLoaded();
    final JellyfinClient? client = _client;
    final JellyfinSession? session = _session?.call();
    if (client == null || session == null) return;
    try {
      final Set<String> serverIds = await client.fetchFavoriteIds(session);
      // Skip the emit/save when nothing actually changed, to avoid churn.
      if (serverIds.length == _data.remoteIds.length &&
          serverIds.containsAll(_data.remoteIds)) {
        return;
      }
      _data = _data.copyWith(remoteIds: serverIds);
      _emit();
      await _store.save(_data);
    } catch (_) {
      // Offline or transient: keep what we have.
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
