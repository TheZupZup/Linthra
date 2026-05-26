import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import 'library_controller.dart';
import 'library_grouping.dart';

/// Albums derived from the loaded track catalog, recomputed whenever the
/// library reloads (scan, sync, or a removal). The Albums tab and the artist
/// detail read from here so grouping lives in exactly one place.
final libraryAlbumsProvider = Provider<List<Album>>((ref) {
  return groupAlbums(ref.watch(libraryControllerProvider).tracks);
});

/// Artists derived from the loaded track catalog. See [libraryAlbumsProvider].
final libraryArtistsProvider = Provider<List<Artist>>((ref) {
  return groupArtists(ref.watch(libraryControllerProvider).tracks);
});
