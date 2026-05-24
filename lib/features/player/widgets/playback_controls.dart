import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/services/playback_controller.dart';
import '../player_providers.dart';

/// The transport row: shuffle · previous · play/pause · next · repeat.
///
/// Shuffle and repeat are deliberately disabled placeholders — they hold their
/// place in the layout for when those modes land, but never pretend to work.
/// Previous/next reflect the live queue (disabled at the ends) and delegate to
/// the existing queue controls; play/pause forwards straight to the controller
/// and shows a spinner while a track loads.
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({required this.state, super.key});

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playbackControllerProvider);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Disabled placeholder until shuffle lands; holds its place in the row.
        const IconButton(
          onPressed: null,
          icon: Icon(Icons.shuffle),
          tooltip: 'Shuffle',
        ),
        IconButton(
          iconSize: 36,
          onPressed: state.hasPrevious ? controller.skipToPrevious : null,
          icon: const Icon(Icons.skip_previous),
          tooltip: 'Previous',
        ),
        _PlayPauseButton(state: state, controller: controller),
        IconButton(
          iconSize: 36,
          onPressed: state.hasNext ? controller.skipToNext : null,
          icon: const Icon(Icons.skip_next),
          tooltip: 'Next',
        ),
        // Disabled placeholder until repeat lands.
        const IconButton(
          onPressed: null,
          icon: Icon(Icons.repeat),
          tooltip: 'Repeat',
        ),
      ],
    );
  }
}

/// The dominant control: a large filled circle that toggles play/pause and
/// shows a spinner while the next track resolves/buffers.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (state.status == PlaybackStatus.loading) {
      return Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor:
                AlwaysStoppedAnimation<Color>(theme.colorScheme.onPrimary),
          ),
        ),
      );
    }

    final playing = state.isPlaying;
    return SizedBox(
      width: 72,
      height: 72,
      child: IconButton.filled(
        iconSize: 40,
        onPressed: playing ? controller.pause : controller.play,
        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        tooltip: playing ? 'Pause' : 'Play',
      ),
    );
  }
}
