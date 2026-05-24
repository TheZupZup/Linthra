import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../player/favorites_providers.dart';

/// The favourited tracks to show in the Favorites view.
///
/// Joins the favourite id set (from [favoriteIdsProvider] — local-folder
/// favourites plus the Jellyfin server's set, which is the source of truth for
/// remote tracks) against the offline catalog, so every liked track that's in
/// the library appears whether it's local or Jellyfin. Re-resolves whenever the
/// favourite set changes, keeping the list live as hearts toggle.
final favoriteTracksProvider = FutureProvider<List<Track>>((ref) async {
  final Set<String> ids = await ref.watch(favoriteIdsProvider.future);
  if (ids.isEmpty) return const <Track>[];
  final List<Track> tracks =
      await ref.watch(musicLibraryRepositoryProvider).getAllTracks();
  return <Track>[
    for (final Track track in tracks)
      if (ids.contains(track.id)) track,
  ];
});
