import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/models/repeat_mode.dart';
import '../../../core/services/playback_controller.dart';
import '../player_providers.dart';

/// The transport row: shuffle · previous · play/pause · next · repeat.
///
/// Shuffle and repeat are live, controller-driven modes (read from
/// [PlaybackState], toggled/cycled through the [PlaybackController]); the active
/// state is shown with the accent colour and the button's selected styling.
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
        _ShuffleButton(state: state, controller: controller),
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
        _RepeatButton(state: state, controller: controller),
      ],
    );
  }
}

/// Toggles shuffle. Tinted with the accent colour and shown selected while on,
/// so the active state reads at a glance.
class _ShuffleButton extends StatelessWidget {
  const _ShuffleButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = state.shuffleEnabled;
    return IconButton(
      onPressed: () => controller.setShuffleEnabled(!enabled),
      icon: const Icon(Icons.shuffle),
      isSelected: enabled,
      color: enabled ? theme.colorScheme.primary : null,
      tooltip: enabled ? 'Shuffle on' : 'Shuffle',
    );
  }
}

/// Cycles repeat off → all → one → off. The glyph switches to repeat-one in
/// that mode, and the button is tinted/selected whenever repeat is active.
class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = state.repeatMode;
    final active = mode != RepeatMode.off;
    return IconButton(
      onPressed: () => controller.setRepeatMode(mode.next),
      icon: Icon(
        mode == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
      ),
      isSelected: active,
      color: active ? theme.colorScheme.primary : null,
      tooltip: _tooltipFor(mode),
    );
  }

  static String _tooltipFor(RepeatMode mode) {
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
