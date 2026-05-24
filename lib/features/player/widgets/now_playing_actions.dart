import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/lyrics.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../shared/widgets/empty_state.dart';
import '../favorites_providers.dart';
import '../lyrics_providers.dart';
import '../player_providers.dart';

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

/// The lyrics sheet. It follows the *currently playing* track rather than a
/// captured one, so skipping to the next song updates the lines in place; while
/// the new track's lyrics load it shows a spinner (never the previous song),
/// then either the lines, a calm "no lyrics" placeholder, or a friendly
/// "couldn't load" message on a fetch failure.
class _LyricsSheet extends ConsumerWidget {
  const _LyricsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<Lyrics?> lyrics = ref.watch(currentTrackLyricsProvider);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Lyrics', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Flexible(child: _content(lyrics)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(AsyncValue<Lyrics?> lyrics) {
    return lyrics.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      ),
      // Never surface raw error text (it can carry transport detail); show one
      // calm, friendly line instead.
      error: (_, __) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: EmptyState(
          icon: Icons.lyrics_outlined,
          title: "Couldn't load lyrics",
          message: 'Check your connection and try again.',
        ),
      ),
      data: (value) {
        if (value == null || value.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: EmptyState(
              icon: Icons.lyrics_outlined,
              title: 'No lyrics available yet.',
              message: "They'll appear here when your server has them.",
            ),
          );
        }
        return _LyricsList(lyrics: value);
      },
    );
  }
}

class _LyricsList extends StatelessWidget {
  const _LyricsList({required this.lyrics});

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView.builder(
      shrinkWrap: true,
      itemCount: lyrics.lines.length,
      itemBuilder: (context, index) {
        final String text = lyrics.lines[index].text;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          // A blank line keeps its vertical rhythm rather than collapsing.
          child: Text(
            text.isEmpty ? ' ' : text,
            style: theme.textTheme.bodyLarge,
          ),
        );
      },
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
