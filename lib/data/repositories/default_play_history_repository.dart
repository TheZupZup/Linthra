import 'dart:async';

import '../../core/models/play_history.dart';
import '../../core/models/track.dart';
import '../../core/repositories/play_history_repository.dart';
import '../../core/repositories/play_history_store.dart';

/// The app's [PlayHistoryRepository]: an in-memory mirror persisted through a
/// [PlayHistoryStore].
///
/// Loads the stored history lazily on first read, records a completed play by
/// bumping that track's count and last-played time, then emits and persists.
/// Mirrors `SyncedFavoritesRepository`'s shape (load-once, emit, persist) minus
/// any server sync — play history is on-device only.
///
/// Identity is the provider-namespaced [Track.uri], not the bare server-side
/// id, so completing `jellyfin:101` never makes `subsonic:101` look played. A
/// pre-uri store (keyed by the bare id) is migrated to uris once, against the
/// catalog's current owner of each id (see [_maybeMigrateLegacyKeysOnce]); an id
/// the catalog exposes under more than one provider is left untouched rather
/// than mis-attributed.
///
/// Privacy: the stored key is the non-secret [Track.uri] — the same identity the
/// catalog DB and "recently added" store already persist — never a token or an
/// authenticated stream URL, and nothing is sent off the device.
class DefaultPlayHistoryRepository implements PlayHistoryRepository {
  DefaultPlayHistoryRepository({
    required PlayHistoryStore store,
    DateTime Function()? now,
    Future<List<Track>> Function()? catalogForMigration,
  })  : _store = store,
        _now = now ?? DateTime.now,
        _catalogForMigration = catalogForMigration;

  final PlayHistoryStore _store;
  final DateTime Function() _now;

  /// Supplies the current catalog for the one-time bare-id → uri migration, or
  /// null when no migration is needed (tests, the in-memory default). Read lazily
  /// so the migration resolves against the catalog as it stands on first read.
  final Future<List<Track>> Function()? _catalogForMigration;

  final StreamController<PlayHistory> _changes =
      StreamController<PlayHistory>.broadcast();

  PlayHistory _history = PlayHistory.empty;
  bool _loaded = false;

  /// Guards the one-time legacy-key migration so it runs at most once, after the
  /// catalog is available (see [_maybeMigrateLegacyKeysOnce]).
  bool _migratedLegacyKeys = false;

  // Serialises writes so two quick completions can't race on load-then-save and
  // lose a count: each recorded play runs only after the previous one persists.
  Future<void> _writes = Future<void>.value();

  Future<void> _ensureLoaded() async {
    if (!_loaded) {
      _history = await _store.load();
      _loaded = true;
    }
    await _maybeMigrateLegacyKeysOnce();
  }

  @override
  PlayHistory get current => _history;

  @override
  Stream<PlayHistory> get historyStream async* {
    await _ensureLoaded();
    yield _history;
    yield* _changes.stream;
  }

  @override
  Future<void> recordCompletion(Track track) {
    // Capture the provider-namespaced uri (the stable, collision-free identity)
    // and chain onto the write queue.
    final String trackUri = track.uri;
    _writes = _writes.then((_) async {
      try {
        await _ensureLoaded();
        _history = _history.recordPlay(trackUri, _now());
        if (!_changes.isClosed) _changes.add(_history);
        await _store.save(_history);
      } catch (_) {
        // Never throw out of recordCompletion: a failed persist keeps the
        // in-memory count and the next write retries the save.
      }
    });
    return _writes;
  }

  /// Re-keys a pre-uri store's bare-`id`-keyed stats onto the provider-namespaced
  /// [Track.uri], once, after the catalog is available.
  ///
  /// Each legacy bare id is resolved against the catalog's current owner of that
  /// id: a unique owner adopts the count (folding it into any uri-keyed count for
  /// the same track), while an id exposed by more than one provider — or absent
  /// from the catalog — is left as-is. A leftover bare key simply never matches a
  /// `track.uri` at read time, so it can't cross-contaminate another provider; it
  /// is preserved (not dropped) so unambiguous data isn't lost. Runs on first
  /// read, before any new play is recorded, so the legacy count is in place when
  /// the same track is next played.
  Future<void> _maybeMigrateLegacyKeysOnce() async {
    if (_migratedLegacyKeys) return;
    final Future<List<Track>> Function()? oracle = _catalogForMigration;
    if (oracle == null) {
      _migratedLegacyKeys = true;
      return;
    }
    if (_history.stats.isEmpty) {
      _migratedLegacyKeys = true;
      return;
    }
    final List<Track> tracks;
    try {
      tracks = await oracle();
    } catch (_) {
      // Transient catalog read failure: defer so a later read can retry.
      return;
    }
    // An empty catalog this early is almost certainly "not loaded yet" rather
    // than "no library"; defer so we don't strand unambiguous legacy counts.
    if (tracks.isEmpty) return;
    _migratedLegacyKeys = true;

    final Set<String> catalogUris = <String>{
      for (final Track track in tracks) track.uri,
    };
    // bare id -> owner uri, or null when more than one provider exposes that id.
    final Map<String, String?> ownerByBareId = <String, String?>{};
    for (final Track track in tracks) {
      // Local tracks have id == uri, so they are never legacy bare-id-keyed.
      if (track.uri == track.id) continue;
      ownerByBareId[track.id] =
          ownerByBareId.containsKey(track.id) ? null : track.uri;
    }

    PlayHistory migrated = _history;
    for (final String key in _history.stats.keys) {
      // Already a valid uri (local path or namespaced) — nothing to do.
      if (catalogUris.contains(key)) continue;
      final String? ownerUri = ownerByBareId[key];
      // Unknown id, or ambiguous across providers: leave it (don't guess).
      if (ownerUri == null) continue;
      migrated = migrated.remapKey(key, ownerUri);
    }
    if (!identical(migrated, _history)) {
      _history = migrated;
      if (!_changes.isClosed) _changes.add(_history);
      await _store.save(_history);
    }
  }

  Future<void> dispose() => _changes.close();
}
