import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../shared/widgets/empty_state.dart';
import '../favorites_providers.dart';
import '../player_providers.dart';
import 'lyrics_view.dart';

/// Bottom action row on the now-playing screen: favorite · queue · lyrics.
///
/// All three are live: favorite toggles a heart synced through the
/// [FavoritesRepository] (to Jellyfin for remote tracks, on-device for local
/// ones), queue opens the up-next list, and lyrics fetches the track's lyrics
/// from the source — falling back to an honest "no lyrics" state when there are
/// none (or for a local track / when signed out).
class NowPlayingActions extends ConsumerWidget {
  const NowPlayingActions({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool isFavorite = ref.watch(isFavoriteProvider(track.id));

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          onPressed: () => ref
              .read(favoritesRepositoryProvider)
              .setFavorite(track, !isFavorite),
          icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
          color: isFavorite ? theme.colorScheme.primary : null,
          isSelected: isFavorite,
          tooltip: isFavorite ? 'Remove from favorites' : 'Favorite',
        ),
        IconButton(
          onPressed: () => _openQueue(context),
          icon: const Icon(Icons.queue_music_outlined),
          tooltip: 'Queue',
        ),
        IconButton(
          onPressed: () => _openLyrics(context),
          icon: const Icon(Icons.lyrics_outlined),
          tooltip: 'Lyrics',
        ),
      ],
    );
  }

  void _openQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _QueueSheet(),
    );
  }

  void _openLyrics(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _LyricsSheet(),
    );
  }
}

/// The lyrics sheet: a tall, premium synced-lyrics panel. It follows the
/// *currently playing* track rather than a captured one, so skipping updates the
/// lines in place; the heavy lifting (loading / empty / plain / synced
/// highlighting + auto-scroll) lives in [LyricsView]. Opening it only reads
/// playback state — it never starts or restarts playback.
class _LyricsSheet extends StatelessWidget {
  const _LyricsSheet();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.lyrics_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Lyrics', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const Expanded(child: LyricsView()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The queue sheet: the playing track followed by the live up-next list, with a
/// Clear action. Watches playback state so it stays current while open.
class _QueueSheet extends ConsumerWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;
    final upNext = state.upNext;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Text('Up next', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  if (upNext.isNotEmpty)
                    TextButton(
                      onPressed: controller.clearQueue,
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            Flexible(
              child: upNext.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                      child: EmptyState(
                        icon: Icons.queue_music_outlined,
                        title: 'Nothing up next',
                        message: 'Tracks you queue will appear here.',
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: upNext.length,
                      itemBuilder: (context, index) =>
                          _QueueTile(track: upNext[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final artist = track.artistName;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.queue_music_outlined),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: artist == null || artist.isEmpty
          ? null
          : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
