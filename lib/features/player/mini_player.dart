import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/colors.dart';
import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/track.dart';
import 'cast/cast_providers.dart';
import 'player_providers.dart';
import 'widgets/album_artwork.dart';

/// A compact, persistent now-playing bar shown above the bottom navigation on
/// every main screen (Library / Playlists / Downloads / Settings).
///
/// It renders from [playbackStateProvider] — the same single
/// [PlaybackController] the full [PlayerScreen] and the media session use — so
/// it never owns playback state of its own and never disappears when switching
/// tabs. When nothing is loaded it collapses to zero height. Tapping it opens
/// the full now-playing screen; the play/pause button delegates straight to the
/// controller. A thin accent progress line rides its top edge, doubling as the
/// separator from the content above.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch only the current track (id-distinct), so the ~5 Hz position ticks
    // rebuild just the thin progress line and the play/pause button below — not
    // the whole bar (artwork, text) on every screen, every tick. Falls back to
    // the controller's latest state until the first stream event arrives.
    final Track? streamed = ref.watch(
      playbackStateProvider.select((s) => s.valueOrNull?.currentTrack),
    );
    final Track? track =
        streamed ?? ref.read(playbackControllerProvider).state.currentTrack;

    // Collapse entirely when there is nothing to show, so screens without a
    // loaded track look exactly as they did before.
    if (track == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final bool isCasting = ref.watch(
      castStateProvider.select((s) => s.valueOrNull?.isConnected ?? false),
    );
    final subtitle = _subtitle(track);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.push(AppRoutes.player),
        child: SizedBox(
          height: 64,
          child: Column(
            children: [
              const _MiniProgressBar(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 44,
                        child: AlbumArtwork(
                          artworkUri: track.artworkUri,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      if (isCasting) ...[
                        Icon(
                          Icons.cast_connected,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                      const SizedBox(width: AppSpacing.sm),
                      const _PlayPauseButton(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Artist • album when present; falls back to artist or album alone, and to
  /// nothing when the track carries no metadata.
  static String? _subtitle(Track track) {
    final String label = track.artistAlbumLabel;
    return label.isEmpty ? null : label;
  }
}

/// A 2.5dp accent line tracking playback progress across the mini-player's top
/// edge. Sits at 0 (an empty track) when the duration is still unknown, so it
/// never animates indeterminately or jumps.
///
/// It watches the position/duration itself, so a position tick rebuilds only
/// this thin line — not the artwork and text above it.
class _MiniProgressBar extends ConsumerWidget {
  const _MiniProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;
    final theme = Theme.of(context);
    final int total = state.duration.inMilliseconds;
    final double value = total > 0
        ? (state.position.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;
    return LinearProgressIndicator(
      value: value,
      minHeight: 2.5,
      backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
      color: AppColors.accent,
    );
  }
}

/// The mini-player's transport control: a spinner while a track loads, then a
/// play/pause toggle (tinted with the warm accent) that forwards to the
/// controller. Watches the playback status itself so it stays live even though
/// the bar around it only rebuilds when the track changes.
class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;
    // A spinner for both preparing and mid-stream buffering, so the mini-player
    // shows activity (never looks frozen) while the stream catches up.
    if (state.isBusy) {
      return const SizedBox.square(
        dimension: 24,
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.xs),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final playing = state.isPlaying;
    return IconButton(
      onPressed: playing ? controller.pause : controller.play,
      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
      iconSize: 30,
      color: Theme.of(context).colorScheme.secondary,
      tooltip: playing ? 'Pause' : 'Play',
    );
  }
}
