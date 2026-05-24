import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../shared/widgets/empty_state.dart';
import '../library/widgets/alphabet_track_list.dart';
import 'favorites_controller.dart';

/// The Favorites library view: every track the user has liked, local or
/// Jellyfin. Reads entirely from [favoriteTracksProvider] and reuses the same
/// [AlphabetTrackList]/`TrackTile` rows as the main library, so tapping a
/// favourite plays it and queues the rest behind it — unchanged from the
/// library. Shows an honest empty state when nothing is favourited yet.
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoriteTracksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: favorites.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const _FavoritesError(),
        data: (tracks) => tracks.isEmpty
            ? const EmptyState(
                icon: Icons.favorite_border,
                title: 'No favorites yet',
                message: 'Tap the heart on a track to add it here.',
              )
            : AlphabetTrackList(tracks: tracks),
      ),
    );
  }
}

class _FavoritesError extends StatelessWidget {
  const _FavoritesError();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: AppSpacing.md),
            Text(
              "Couldn't load your favorites",
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
