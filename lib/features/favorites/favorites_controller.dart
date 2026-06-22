import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track.dart';
import '../../data/repositories/music_library_repository_provider.dart';
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
  final Set<String> ids = await ref.watch(favoriteIdsProvider.future);
  if (ids.isEmpty) return const <Track>[];
  final List<Track> tracks =
      await ref.watch(musicLibraryRepositoryProvider).getAllTracks();
  return <Track>[
    for (final Track track in tracks)
      if (ids.contains(track.uri)) track,
  ];
});
