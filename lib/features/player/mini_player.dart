import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/colors.dart';
import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/playback_state.dart';
import '../../core/services/playback_controller.dart';
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
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;

    // Collapse entirely when there is nothing to show, so screens without a
    // loaded track look exactly as they did before.
    if (!state.hasTrack) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final track = state.currentTrack!;
    final bool isCasting = ref.watch(
      castStateProvider.select((s) => s.valueOrNull?.isConnected ?? false),
    );
    final subtitle = _subtitle(state);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.push(AppRoutes.player),
        child: SizedBox(
          height: 64,
          child: Column(
            children: [
              _MiniProgressBar(
                position: state.position,
                duration: state.duration,
              ),
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
                      _PlayPauseButton(state: state, controller: controller),
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
  static String? _subtitle(PlaybackState state) {
    final track = state.currentTrack!;
    final parts = <String>[
      if (track.artistName != null && track.artistName!.isNotEmpty)
        track.artistName!,
      if (track.albumName != null && track.albumName!.isNotEmpty)
        track.albumName!,
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }
}

/// A 2.5dp accent line tracking playback progress across the mini-player's top
/// edge. Sits at 0 (an empty track) when the duration is still unknown, so it
/// never animates indeterminately or jumps.
class _MiniProgressBar extends StatelessWidget {
  const _MiniProgressBar({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int total = duration.inMilliseconds;
    final double value =
        total > 0 ? (position.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
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
/// controller.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
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
