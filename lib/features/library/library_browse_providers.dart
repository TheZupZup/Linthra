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
