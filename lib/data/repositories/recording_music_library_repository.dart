import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/incremental_catalog_writer.dart';
import '../../core/repositories/library_added_store.dart';
import '../../core/repositories/music_library_repository.dart';

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
/// from two providers can't share — or clobber — one timestamp. Stores stamped
/// under the old id key are migrated to the uri key in place the first time each
/// track is seen again (see [_stampFirstSeen]), preserving the original time.
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
  /// Entries are keyed by [Track.uri]. A timestamp left under the legacy bare-`id`
  /// key (from before this store was provider-namespaced) is migrated to the uri
  /// key in place — preserving the original time — the first time the track is
  /// seen again, so an upgrade never resets a user's "recently added" ordering.
  Future<void> _stampFirstSeen(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final Map<String, DateTime> addedAt = await _addedStore.load();
    final DateTime now = _now();
    bool changed = false;
    for (final Track track in tracks) {
      if (addedAt.containsKey(track.uri)) continue;
      // Adopt a legacy id-keyed timestamp if one exists (and id != uri, i.e. a
      // remote track); otherwise this is genuinely new and gets `now`.
      final DateTime? legacy =
          track.uri == track.id ? null : addedAt.remove(track.id);
      addedAt[track.uri] = legacy ?? now;
      changed = true;
    }
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
    }
    if (changed) await _addedStore.save(addedAt);
  }
}
