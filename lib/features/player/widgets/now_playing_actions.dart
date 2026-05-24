import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/track.dart';
import '../../../shared/widgets/empty_state.dart';
import '../player_providers.dart';

/// Bottom action row on the now-playing screen: favorite · queue · lyrics.
///
/// Favorite and lyrics are honest placeholders — they give feedback but don't
/// pretend to persist or fetch anything. Queue opens the live up-next list in a
/// sheet, keeping the main screen artwork-focused.
class NowPlayingActions extends ConsumerWidget {
  const NowPlayingActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          onPressed: () => _comingSoon(context, 'Favorites are coming soon.'),
          icon: const Icon(Icons.favorite_border),
          tooltip: 'Favorite',
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

  void _comingSoon(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
      builder: (_) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.xl),
          child: EmptyState(
            icon: Icons.lyrics_outlined,
            title: 'No lyrics available yet.',
            message: 'Lyrics support is coming in a future update.',
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
