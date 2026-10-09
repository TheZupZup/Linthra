import 'dart:async';

import '../../core/models/play_history.dart';
import '../../core/models/track.dart';
import '../../core/repositories/local_store_write_exception.dart';
import '../../core/repositories/play_history_repository.dart';
import '../../core/repositories/play_history_store.dart';
import '../../core/repositories/track_identity_reassignable.dart';
import '../../core/services/song_origins.dart';
import '../../core/services/stability_diagnostics.dart';

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
/// A play of a Subsonic or Plex song also records where it was made
/// ([SongOrigins], #795), since the same id names another song on another
/// server: `subsonic:48211` played on two servers counts as two songs. The
/// history this exposes ([current], [historyStream]) is the one for the
/// servers signed in now, keyed by plain uri; another server's plays are kept
/// and come back with it.
///
/// Privacy: the stored key is the non-secret [Track.uri] — the same identity the
/// catalog DB and "recently added" store already persist — never a token or an
/// authenticated stream URL, and nothing is sent off the device. The origin
/// recorded beside it is a one-way account fingerprint or a Plex server's
/// public machine identifier.
class DefaultPlayHistoryRepository
    implements PlayHistoryRepository, TrackIdentityReassignable {
  DefaultPlayHistoryRepository({
    required PlayHistoryStore store,
    DateTime Function()? now,
    Future<List<Track>> Function()? catalogForMigration,
    SongOrigins origins = const UnboundSongOrigins(),
  })  : _store = store,
        _now = now ?? DateTime.now,
        _catalogForMigration = catalogForMigration,
        _origins = origins {
    _originChanges = origins.changes.listen((_) {
      if (_loaded) _publish();
    });
  }

  final SongOrigins _origins;
  late final StreamSubscription<void> _originChanges;

  final PlayHistoryStore _store;
  final DateTime Function() _now;

  /// Supplies the current catalog for the one-time bare-id → uri migration, or
  /// null when no migration is needed (tests, the in-memory default). Read lazily
  /// so the migration resolves against the catalog as it stands on first read.
  final Future<List<Track>> Function()? _catalogForMigration;

  final StreamController<PlayHistory> _changes =
      StreamController<PlayHistory>.broadcast();

  /// Everything recorded, keyed by [songHistoryKey].
  PlayHistory _history = PlayHistory.empty;

  /// [_history] as the servers signed in now see it (see [_viewOf]).
  PlayHistory _view = PlayHistory.empty;
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
      _view = _viewOf(_history, _origins);
      _loaded = true;
    }
    await _maybeMigrateLegacyKeysOnce();
  }

  @override
  PlayHistory get current => _view;

  @override
  Stream<PlayHistory> get historyStream async* {
    await _ensureLoaded();
    yield _view;
    yield* _changes.stream;
  }

  /// Works out [_view] again and emits it.
  void _publish() {
    _view = _viewOf(_history, _origins);
    if (!_changes.isClosed) _changes.add(_view);
  }

  /// [history] keyed by plain uri, holding only the plays of songs the
  /// library means now: every play of a song whose provider records no
  /// origin, and for the others the plays made on the origin signed in now
  /// (an older play, recorded without one, counts for the origin its kind
  /// was settled to). Two keys that land on one uri add up.
  static PlayHistory _viewOf(PlayHistory history, SongOrigins origins) {
    final Map<String, TrackPlayStats> stats = <String, TrackPlayStats>{};
    for (final MapEntry<String, TrackPlayStats> entry
        in history.stats.entries) {
      final ({String uri, String? origin}) key = splitSongHistoryKey(entry.key);
      if (!songOriginMatches(origins, key.uri, key.origin)) continue;
      final TrackPlayStats? earlier = stats[key.uri];
      stats[key.uri] = earlier == null
          ? entry.value
          : TrackPlayStats(
              playCount: earlier.playCount + entry.value.playCount,
              lastPlayedAt:
                  earlier.lastPlayedAt.isAfter(entry.value.lastPlayedAt)
                      ? earlier.lastPlayedAt
                      : entry.value.lastPlayedAt,
            );
    }
    return PlayHistory(stats: stats);
  }

  @override
  Future<void> recordCompletion(Track track) {
    // Capture the provider-namespaced uri (the stable, collision-free identity)
    // and where the song was played, then chain onto the write queue.
    final String trackUri = track.uri;
    final String? origin = songOriginToRecord(_origins, trackUri);
    // Finished while its server was signed out: no stored reference could
    // say which server's song it was, so it isn't counted for any.
    if (origin == noSongOrigin) return _writes;
    final String key = songHistoryKey(trackUri, origin);
    _writes = _writes.then((_) async {
      try {
        await _ensureLoaded();
        _history = _history.recordPlay(key, _now());
        // Current at once, kept in memory even if the save below is refused.
        _view = _viewOf(_history, _origins);
        await _store.save(_history);
        if (!_changes.isClosed) _changes.add(_view);
      } on LocalStoreWriteException catch (error) {
        // Playback completion is a background side effect, so it must not throw
        // into the player. Keep the in-memory count for the next retry, but make
        // the failed durable write visible in the secret-free diagnostics.
        StabilityDiagnostics.localStoreWriteFailure(error.area.name);
      } catch (_) {
        // Never throw out of recordCompletion: a failed persist keeps the
        // in-memory count and the next write retries the save.
      }
    });
    return _writes;
  }

  /// Carries a moved local file's play count and last-played time to its new
  /// path, on the same write queue as [recordCompletion] so it cannot race a
  /// play being recorded at either end.
  ///
  /// [PlayHistory.remapKey] does the merging: if the new path somehow already
  /// had stats (the same song was there before, then replaced) the counts add
  /// up and the later last-played time wins, so nothing is lost either way.
  ///
  /// Saved before it becomes the history, unlike a recorded play: a refused
  /// save leaves the counts where they were and completes with false, so the
  /// move is kept and asked again. Kept only in memory, it would be gone with
  /// the next launch, while the move itself would already count as done.
  /// Asked again after it landed, it finds nothing under the old path.
  @override
  Future<bool> reassignTrack({
    required String fromUri,
    required String toUri,
  }) {
    final Future<bool> moved = _writes.then((_) async {
      try {
        await _ensureLoaded();
        final PlayHistory remapped = _history.remapKey(fromUri, toUri);
        if (identical(remapped, _history)) return true;
        await _store.save(remapped);
        _history = remapped;
        _publish();
        return true;
      } on LocalStoreWriteException catch (error) {
        StabilityDiagnostics.localStoreWriteFailure(error.area.name);
        return false;
      } catch (error) {
        StabilityDiagnostics.trackMoveFailedUnexpectedly('playHistory', error);
        return false;
      }
    });
    _writes = moved;
    return moved;
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
      _publish();
      await _store.save(_history);
    }
  }

  Future<void> dispose() async {
    await _originChanges.cancel();
    await _changes.close();
  }
}
