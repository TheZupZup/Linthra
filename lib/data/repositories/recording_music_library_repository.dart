import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/incremental_catalog_writer.dart';
import '../../core/repositories/library_added_store.dart';
import '../../core/repositories/music_library_repository.dart';
import '../../core/sources/music_provider.dart';

/// A [MusicLibraryRepository] decorator that stamps each track with the time it
/// first entered the library, so the "Recently added" smart mix has a signal to
/// rank by.
///
/// It wraps the real repository and, on every [upsertCatalog] (the single point
/// every source — local, Jellyfin, Subsonic, Plex — funnels a scan/sync
/// through), records `now` for any track not seen before, preserving the original
/// timestamp for tracks that already had one. That means a routine re-sync never
/// resets "recently added": only genuinely new tracks bubble to the top.
/// [removeTracks] forgets the timestamps for the tracks it removes, so a track
/// that's removed and later re-added is correctly treated as new again.
///
/// The map is keyed by the provider-namespaced [Track.uri] (e.g. `jellyfin:101`,
/// `plex:101`, or a local path), not the bare `id`, so the same server-side id
/// from two providers can't share — or clobber — one timestamp. A store written
/// by a pre-v2 build (keyed by the bare id) is migrated to uri keys once, before
/// the first catalog write, against the catalog's current owner of each id (see
/// [_migrateLegacyAddedKeysOnce]) — so the original time lands on the row that
/// owned it and a later same-id row from a newly-added provider can't steal it.
///
/// Reads (`getAllTracks`, etc.) pass straight through. The stored map holds only
/// non-secret, namespaced track uris and timestamps; it never carries a token or
/// an authenticated URL.
///
/// Incremental writes ([beginCatalogReplacement] / [appendToCatalog]) stamp each
/// streamed batch the same way [upsertCatalog] does, so a progressively-synced
/// library still feeds "Recently added" correctly; they delegate to the wrapped
/// repository's [IncrementalCatalogWriter] when it has one (the production Drift
/// repository does) and otherwise fall back to a whole-slice write.
class RecordingMusicLibraryRepository
    implements MusicLibraryRepository, IncrementalCatalogWriter {
  RecordingMusicLibraryRepository({
    required MusicLibraryRepository delegate,
    required LibraryAddedStore addedStore,
    DateTime Function()? now,
  })  : _delegate = delegate,
        _addedStore = addedStore,
        _now = now ?? DateTime.now;

  final MusicLibraryRepository _delegate;
  final LibraryAddedStore _addedStore;
  final DateTime Function() _now;

  /// Guards the one-time legacy added-at key migration so it runs at most once,
  /// at the first catalog write (see [_migrateLegacyAddedKeysOnce]).
  bool _migratedLegacyAddedKeys = false;

  @override
  Future<List<Track>> getAllTracks() => _delegate.getAllTracks();

  @override
  Future<List<Album>> getAllAlbums() => _delegate.getAllAlbums();

  @override
  Future<List<Artist>> getAllArtists() => _delegate.getAllArtists();

  @override
  Future<Track?> getTrackByUri(String uri) => _delegate.getTrackByUri(uri);

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    await _migrateLegacyAddedKeysOnce();
    await _delegate.upsertCatalog(
      sourceId: sourceId,
      tracks: tracks,
      albums: albums,
      artists: artists,
    );
    await _stampFirstSeen(tracks);
  }

  @override
  Future<void> beginCatalogReplacement({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    await _migrateLegacyAddedKeysOnce();
    final MusicLibraryRepository delegate = _delegate;
    if (delegate is IncrementalCatalogWriter) {
      await (delegate as IncrementalCatalogWriter)
          .beginCatalogReplacement(sourceId: sourceId, tracks: tracks);
    } else {
      await delegate.upsertCatalog(
        sourceId: sourceId,
        tracks: tracks,
        albums: const <Album>[],
        artists: const <Artist>[],
      );
    }
    await _stampFirstSeen(tracks);
  }

  @override
  Future<void> appendToCatalog({
    required String sourceId,
    required List<Track> tracks,
  }) async {
    await _migrateLegacyAddedKeysOnce();
    final MusicLibraryRepository delegate = _delegate;
    if (delegate is IncrementalCatalogWriter) {
      await (delegate as IncrementalCatalogWriter)
          .appendToCatalog(sourceId: sourceId, tracks: tracks);
    }
    await _stampFirstSeen(tracks);
  }

  /// Records `now` as the first-seen time for any track not seen before,
  /// preserving earlier timestamps so a routine re-sync never resets "recently
  /// added". Shared by the whole-catalog and incremental write paths.
  ///
  /// Entries are keyed by [Track.uri]. Legacy bare-`id`-keyed timestamps are
  /// re-keyed to the owning uri by [_migrateLegacyAddedKeysOnce] (which runs
  /// before any catalog write), so by the time a track is stamped here a missing
  /// uri key always means genuinely new — never a legacy entry to adopt.
  Future<void> _stampFirstSeen(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final Map<String, DateTime> addedAt = await _addedStore.load();
    final DateTime now = _now();
    bool changed = false;
    for (final Track track in tracks) {
      if (addedAt.containsKey(track.uri)) continue;
      addedAt[track.uri] = now;
      changed = true;
    }
    if (changed) await _addedStore.save(addedAt);
  }

  /// Migrates a pre-v2 store's bare-`id`-keyed timestamps onto the
  /// provider-namespaced [Track.uri] key, once, before the first catalog write.
  ///
  /// Each legacy id is resolved against the catalog's *current* owner of that id.
  /// Running before the first write is what makes this safe: the catalog is still
  /// the upgraded-in-place, 1:1 bare-id→provider state, so the timestamp lands on
  /// the row that actually owned it — a later same-id row from a newly-added
  /// provider (synced after this) can't adopt it. A bare id the catalog already
  /// exposes under more than one provider is left untouched (ambiguous → not
  /// mis-attributed; the read-time fallback still surfaces it).
  Future<void> _migrateLegacyAddedKeysOnce() async {
    if (_migratedLegacyAddedKeys) return;
    _migratedLegacyAddedKeys = true;
    final Map<String, DateTime> addedAt = await _addedStore.load();
    if (addedAt.isEmpty) return;
    // bare id -> owner uri, or null when more than one provider exposes that id.
    final Map<String, String?> ownerByBareId = <String, String?>{};
    for (final Track track in await _delegate.getAllTracks()) {
      if (track.uri == track.id)
        continue; // local: id == uri, never legacy-keyed
      ownerByBareId[track.id] =
          ownerByBareId.containsKey(track.id) ? null : track.uri;
    }
    bool changed = false;
    ownerByBareId.forEach((String bareId, String? ownerUri) {
      if (ownerUri == null)
        return; // ambiguous — leave for the read-time fallback
      final DateTime? legacy = addedAt[bareId];
      if (legacy == null) return;
      // Don't clobber an existing uri-keyed time; just drop the legacy key.
      addedAt.putIfAbsent(ownerUri, () => legacy);
      addedAt.remove(bareId);
      changed = true;
    });
    if (changed) await _addedStore.save(addedAt);
  }

  @override
  Future<void> removeTracks(List<String> trackUris) async {
    await _delegate.removeTracks(trackUris);
    if (trackUris.isEmpty) return;
    final Map<String, DateTime> addedAt = await _addedStore.load();
    bool changed = false;
    for (final String uri in trackUris) {
      if (addedAt.remove(uri) != null) changed = true;
      // Also drop a pre-v2 bare-id entry for a remote track that hasn't been
      // migrated yet, so a remove-then-readd before the first post-upgrade sync
      // is correctly treated as newly added (rather than adopting the stale
      // legacy timestamp in _stampFirstSeen).
      final String? legacyId = MusicProviders.bareRemoteIdForTrackUri(uri);
      if (legacyId != null && addedAt.remove(legacyId) != null) changed = true;
    }
    if (changed) await _addedStore.save(addedAt);
  }
}
