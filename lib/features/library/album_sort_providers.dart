import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/library_grouping.dart';
import '../../core/models/album.dart';
import '../../core/models/track.dart';
import '../../core/repositories/library_song_sort_store.dart';
import '../../data/repositories/library_album_sort_store_provider.dart';
import 'album_sort.dart';
import 'library_browse_providers.dart';
import 'remembered_sort.dart';
import 'song_sort_providers.dart';
import 'unified_library_providers.dart';

/// The order the Albums grid is in, remembered across launches and apart from
/// the Songs list's.
class AlbumSortController extends RememberedSortController<AlbumSort> {
  @override
  AlbumSort get fallback => AlbumSort.fallback;

  @override
  AlbumSort? byName(String? name) => AlbumSort.byName(name);

  @override
  LibrarySongSortStore get store => ref.read(libraryAlbumSortStoreProvider);
}

final albumSortControllerProvider =
    NotifierProvider<AlbumSortController, AlbumSort>(AlbumSortController.new);

/// When each album was added, keyed by its id, for the "Date added" orders:
/// the earliest of its songs' times ([librarySongAddedAtProvider]), which is
/// when the album entered the library. A song added to it later doesn't move
/// it, the way Jellyfin keeps an album's own `DateCreated`. An album none of
/// whose songs has a time is left out.
///
/// Auto-disposed, so it is only worked out while a date order is on screen.
final libraryAlbumAddedAtProvider =
    FutureProvider.autoDispose<Map<String, DateTime>>((ref) async {
  final List<Track> tracks = ref.watch(libraryUnifiedTracksProvider);
  final Map<String, DateTime> bySong =
      await ref.watch(librarySongAddedAtProvider.future);
  final Map<String, DateTime> byAlbum = <String, DateTime>{};
  for (final Track track in tracks) {
    final DateTime? at = bySong[track.uri];
    if (at == null) continue;
    final String album = albumIdForTrack(track);
    final DateTime? earliest = byAlbum[album];
    if (earliest == null || at.isBefore(earliest)) byAlbum[album] = at;
  }
  return byAlbum;
});

/// Every album in the order the Albums grid is in, worked out once per change
/// of order or of catalog rather than on every rebuild. A search filters this,
/// which keeps the order.
///
/// Null while a date order waits for its first dates, so the grid shows that
/// it is sorting rather than an order that is about to change; a reload keeps
/// the previous dates on screen.
final librarySortedAlbumsProvider = Provider.autoDispose<List<Album>?>((ref) {
  final List<Album> albums = ref.watch(libraryAlbumsProvider);
  final AlbumSort sort = ref.watch(albumSortControllerProvider);
  if (sort.field != AlbumSortField.dateAdded) return sortAlbums(albums, sort);
  final AsyncValue<Map<String, DateTime>> addedAt =
      ref.watch(libraryAlbumAddedAtProvider);
  if (addedAt.isLoading && !addedAt.hasValue) return null;
  return sortAlbums(
    albums,
    sort,
    addedAt: addedAt.valueOrNull ?? const <String, DateTime>{},
  );
});
