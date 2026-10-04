import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../library/library_controller.dart';
import '../library/library_state.dart';
import '../player/favorites_providers.dart';

/// The favourited tracks to show in the Favorites view.
///
/// Joins the favourite uri set (from [favoriteIdsProvider] — local-folder
/// favourites plus the Jellyfin server's set, which is the source of truth for
/// remote tracks) against the offline catalog, matching on the
/// provider-namespaced [Track.uri] so a same-id track from another provider is
/// never surfaced by mistake. Re-resolves whenever the favourite set changes,
/// keeping the list live as hearts toggle.
final favoriteTracksProvider = FutureProvider<List<Track>>((ref) async {
  // The catalog changes under the hearts too (a removed song or folder, a
  // disconnected server, a sync), and the library reloads after each of those.
  ref.watch(libraryControllerProvider.select((LibraryState s) => s.tracks));
  final Set<String> ids = await ref.watch(favoriteIdsProvider.future);
  if (ids.isEmpty) return const <Track>[];
  final List<Track> tracks =
      await ref.watch(musicLibraryRepositoryProvider).getAllTracks();
  return <Track>[
    for (final Track track in tracks)
      if (ids.contains(track.uri)) track,
  ];
});
