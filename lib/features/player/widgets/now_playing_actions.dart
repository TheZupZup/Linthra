import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../favorites_providers.dart';
import 'lyrics_view.dart';
import 'queue_sheet.dart';

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
          onPressed: () => showAddToPlaylistSheet(context, <Track>[track]),
          icon: const Icon(Icons.playlist_add),
          tooltip: 'Add to playlist',
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
    showQueueSheet(context);
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
