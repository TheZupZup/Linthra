import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/library_grouping.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import 'unified_library_providers.dart';

/// Albums derived from the unified (de-duplicated) catalog, recomputed whenever
/// the library reloads (scan, sync, or a removal) or the source preference
/// changes. The Albums tab and the artist detail read from here so grouping
/// lives in exactly one place — and grouping logical tracks (not raw per-provider
/// rows) keeps a song that exists on two servers from being counted twice.
final libraryAlbumsProvider = Provider<List<Album>>((ref) {
  return groupAlbums(ref.watch(libraryUnifiedTracksProvider));
});

/// Artists derived from the unified catalog. See [libraryAlbumsProvider].
final libraryArtistsProvider = Provider<List<Artist>>((ref) {
  return groupArtists(ref.watch(libraryUnifiedTracksProvider));
});

/// The album ids the catalog can actually open a page for.
///
/// Not every track on screen comes from the flat catalog: the folder browser
/// lists a server's tree on demand, so it can show a track whose album has
/// never been synced. `AlbumDetailScreen` resolves its id against
/// [libraryAlbumsProvider] alone, so a row like that must not offer "Show
/// album" (#386) — the page it would open says "Album not found".
///
/// A set rather than a scan: the menu asks this per row, and a linear walk of
/// every album on a large library would be an O(N) pass per open.
final libraryAlbumIdsProvider = Provider<Set<String>>((ref) {
  return <String>{
    for (final Album album in ref.watch(libraryAlbumsProvider)) album.id,
  };
});

/// The artist ids the catalog can open a page for. See [libraryAlbumIdsProvider].
final libraryArtistIdsProvider = Provider<Set<String>>((ref) {
  return <String>{
    for (final Artist artist in ref.watch(libraryArtistsProvider)) artist.id,
  };
});
