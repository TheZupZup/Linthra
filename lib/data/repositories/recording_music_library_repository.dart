import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/library_added_store.dart';
import '../../core/repositories/music_library_repository.dart';

/// A [MusicLibraryRepository] decorator that stamps each track with the time it
/// first entered the library, so the "Recently added" smart mix has a signal to
/// rank by.
///
/// It wraps the real repository and, on every [upsertCatalog] (the single point
/// every source — local, Jellyfin, Subsonic — funnels a scan/sync through),
/// records `now` for any track id not seen before, preserving the original
/// timestamp for ids that already had one. That means a routine re-sync never
/// resets "recently added": only genuinely new tracks bubble to the top.
/// [removeTracks] forgets the timestamps for ids it removes, so a track that's
/// removed and later re-added is correctly treated as new again.
///
/// Reads (`getAllTracks`, etc.) pass straight through. The stored map holds only
/// non-secret track ids and timestamps; it never carries a uri or token.
class RecordingMusicLibraryRepository implements MusicLibraryRepository {
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
  Future<Track?> getTrackById(String id) => _delegate.getTrackById(id);

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
    final Map<String, DateTime> addedAt = await _addedStore.load();
    final DateTime now = _now();
    bool changed = false;
    for (final Track track in tracks) {
      if (!addedAt.containsKey(track.id)) {
        addedAt[track.id] = now;
        changed = true;
      }
    }
    if (changed) await _addedStore.save(addedAt);
  }

  @override
  Future<void> removeTracks(List<String> trackIds) async {
    await _delegate.removeTracks(trackIds);
    if (trackIds.isEmpty) return;
    final Map<String, DateTime> addedAt = await _addedStore.load();
    bool changed = false;
    for (final String id in trackIds) {
      if (addedAt.remove(id) != null) changed = true;
    }
    if (changed) await _addedStore.save(addedAt);
  }
}
