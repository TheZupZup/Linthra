import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/repeat_mode.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../favorites_providers.dart';
import '../lyrics_screen.dart';
import '../player_providers.dart';
import 'queue_sheet.dart';

/// The secondary action row on the now-playing screen:
/// shuffle · repeat · favorite · lyrics · queue.
///
/// Shuffle and repeat are live, controller-driven modes (read from the unified
/// playback state, lit in the warm accent when active); favorite toggles a heart
/// synced through the [FavoritesRepository]; lyrics opens the dedicated lyrics
/// page; and queue opens the up-next sheet. Add-to-playlist and the sleep timer
/// live in the now-playing overflow menu, keeping this row to the five controls
/// a listener reaches for during a song.
class NowPlayingActions extends ConsumerWidget {
  const NowPlayingActions({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool isFavorite = ref.watch(isFavoriteProvider(track.id));

    // Live shuffle/repeat, selected down to just those two fields so the row
    // rebuilds on a mode change but never on a position tick. Falls back to the
    // controller's latest state before the first stream event.
    final controller = ref.read(playbackControllerProvider);
    final (bool shuffleEnabled, RepeatMode repeatMode) = ref.watch(
      playbackStateProvider.select((s) {
        final state = s.valueOrNull ?? controller.state;
        return (state.shuffleEnabled, state.repeatMode);
      }),
    );

    // A calm, uniform tint keeps the row reading as tertiary beneath the
    // transport; the live (shuffle/repeat) and favorite controls light up.
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.66);
    final Color accent = theme.colorScheme.secondary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 24,
          onPressed: () => controller.setShuffleEnabled(!shuffleEnabled),
          icon: const Icon(Icons.shuffle),
          isSelected: shuffleEnabled,
          color: shuffleEnabled ? accent : muted,
          tooltip: shuffleEnabled ? 'Shuffle on' : 'Shuffle',
        ),
        IconButton(
          iconSize: 24,
          onPressed: () => controller.setRepeatMode(repeatMode.next),
          icon: Icon(
            repeatMode == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
          ),
          isSelected: repeatMode != RepeatMode.off,
          color: repeatMode != RepeatMode.off ? accent : muted,
          tooltip: _repeatTooltip(repeatMode),
        ),
        IconButton(
          iconSize: 24,
          onPressed: () => ref
              .read(favoritesRepositoryProvider)
              .setFavorite(track, !isFavorite),
          icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
          color: isFavorite ? theme.colorScheme.primary : muted,
          isSelected: isFavorite,
          tooltip: isFavorite ? 'Remove from favorites' : 'Favorite',
        ),
        IconButton(
          iconSize: 24,
          onPressed: () => _openLyrics(context),
          icon: const Icon(Icons.lyrics_outlined),
          color: muted,
          tooltip: 'Lyrics',
        ),
        IconButton(
          iconSize: 24,
          onPressed: () => showQueueSheet(context),
          icon: const Icon(Icons.queue_music_outlined),
          color: muted,
          tooltip: 'Queue',
        ),
      ],
    );
  }

  void _openLyrics(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const LyricsScreen()),
    );
  }

  static String _repeatTooltip(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return 'Repeat';
      case RepeatMode.all:
        return 'Repeat all';
      case RepeatMode.one:
        return 'Repeat one';
    }
  }
}
