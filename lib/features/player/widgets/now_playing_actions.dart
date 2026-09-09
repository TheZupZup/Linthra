import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/playback_state.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../favorites_providers.dart';
import '../now_playing_favorite_target.dart';
import '../player_providers.dart';
import '../sleep_timer_controller.dart';
import 'queue_sheet.dart';
import 'sleep_timer_sheet.dart';

/// Bottom action row on the now-playing screen: favorite · playlist · queue ·
/// lyrics · sleep timer.
///
/// They're live: favorite toggles a heart synced through the
/// [FavoritesRepository] (to Jellyfin for remote tracks, on-device for local
/// ones), queue opens the up-next list, lyrics switches the screen into its
/// lyrics-focused mode, and the sleep timer (a moon that lights up while a
/// countdown is running) opens the delay picker.
///
/// Queue is the one action whose *shape* depends on the host surface. A window
/// wide enough to hold a queue beside the cover passes [onToggleQueue], and the
/// button becomes a pane toggle that reads like the lyrics one next to it.
/// Everywhere else it stays what it has always been: a modal sheet over the
/// screen.
class NowPlayingActions extends ConsumerWidget {
  const NowPlayingActions({
    super.key,
    required this.track,
    this.lyricsVisible = false,
    this.onToggleLyrics,
    this.queueVisible = false,
    this.onToggleQueue,
  });

  final Track track;

  /// Whether the screen is currently showing lyrics instead of the artwork, so
  /// the lyrics button can read as the toggle it is.
  final bool lyricsVisible;

  /// Switches the lyrics-focused mode on and off. Null on surfaces that host
  /// the action row without a lyrics area, which leaves the button inert rather
  /// than opening something the caller didn't ask for.
  final VoidCallback? onToggleLyrics;

  /// Whether a hosted queue pane is currently open, so the button can read as
  /// the toggle it becomes. Meaningless without [onToggleQueue].
  final bool queueVisible;

  /// Opens and closes a queue pane the host lays out itself. Null — the default
  /// — keeps the queue a modal sheet, which is the right shape on every surface
  /// without the width for a pane.
  final VoidCallback? onToggleQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final playbackController = ref.watch(playbackControllerProvider);
    // Watch only the track identity, not playback position ticks, so the action
    // row still rebuilds only when the provider-specific current copy changes.
    final Track? currentPlaybackTrack = ref.watch(
          playbackStateProvider.select(
            (async) => async.valueOrNull?.currentTrack,
          ),
        ) ??
        playbackController.state.currentTrack;
    final playbackState = PlaybackState(currentTrack: currentPlaybackTrack);
    final Track favoriteTarget = resolveNowPlayingFavoriteTarget(
      displayTrack: track,
      playbackState: playbackState,
      candidateSource: ref.watch(playbackCandidateSourceProvider),
    );
    final bool isFavorite = ref.watch(isFavoriteProvider(favoriteTarget.uri));
    final bool sleepTimerActive = ref.watch(
      sleepTimerControllerProvider.select((s) => s.isActive),
    );
    // A calm, uniform tint keeps this row reading as tertiary beneath the
    // transport controls; favorite and the sleep timer still light up when
    // active.
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 22,
          onPressed: () => ref
              .read(favoritesRepositoryProvider)
              .setFavorite(favoriteTarget, !isFavorite),
          icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
          color: isFavorite ? theme.colorScheme.primary : muted,
          isSelected: isFavorite,
          tooltip: isFavorite ? 'Remove from favorites' : 'Favorite',
        ),
        IconButton(
          iconSize: 22,
          onPressed: () => showAddToPlaylistSheet(context, <Track>[track]),
          icon: const Icon(Icons.playlist_add),
          color: muted,
          tooltip: 'Add to playlist',
        ),
        IconButton(
          iconSize: 22,
          onPressed: onToggleQueue ?? () => _openQueue(context),
          icon: Icon(
            queueVisible ? Icons.queue_music : Icons.queue_music_outlined,
          ),
          color: queueVisible ? theme.colorScheme.primary : muted,
          isSelected: onToggleQueue == null ? null : queueVisible,
          tooltip: switch ((onToggleQueue != null, queueVisible)) {
            (true, true) => 'Hide queue',
            (true, false) => 'Show queue',
            _ => 'Queue',
          },
        ),
        IconButton(
          iconSize: 22,
          onPressed: onToggleLyrics,
          icon: Icon(
            lyricsVisible ? Icons.lyrics : Icons.lyrics_outlined,
          ),
          color: lyricsVisible ? theme.colorScheme.primary : muted,
          isSelected: lyricsVisible,
          tooltip: lyricsVisible ? 'Hide lyrics' : 'Lyrics',
        ),
        IconButton(
          iconSize: 22,
          onPressed: () => showSleepTimerSheet(context),
          icon: Icon(
            sleepTimerActive ? Icons.bedtime : Icons.bedtime_outlined,
          ),
          color: sleepTimerActive ? theme.colorScheme.primary : muted,
          isSelected: sleepTimerActive,
          tooltip: sleepTimerActive ? 'Sleep timer (on)' : 'Sleep timer',
        ),
      ],
    );
  }

  void _openQueue(BuildContext context) {
    showQueueSheet(context);
  }
}
