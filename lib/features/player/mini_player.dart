import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/playback_state.dart';
import '../../core/services/playback_controller.dart';
import 'player_providers.dart';

/// A compact, persistent now-playing bar shown above the bottom navigation on
/// every main screen (Library / Playlists / Downloads / Settings).
///
/// It renders from [playbackStateProvider] — the same single
/// [PlaybackController] the full [PlayerScreen] and the media session use — so
/// it never owns playback state of its own and never disappears when switching
/// tabs. When nothing is loaded it collapses to zero height. Tapping it opens
/// the full now-playing screen; the play/pause button delegates straight to the
/// controller.
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
    final subtitle = _subtitle(state);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.push(AppRoutes.player),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.music_note, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      style: theme.textTheme.titleSmall,
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
              const SizedBox(width: AppSpacing.sm),
              _PlayPauseButton(state: state, controller: controller),
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

/// The mini-player's transport control: a spinner while a track loads, then a
/// play/pause toggle that forwards to the controller.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    if (state.status == PlaybackStatus.loading) {
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
      tooltip: playing ? 'Pause' : 'Play',
    );
  }
}
