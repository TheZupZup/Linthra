import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/colors.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/models/repeat_mode.dart';
import '../../../core/services/playback_controller.dart';
import '../player_providers.dart';

/// The transport row: shuffle · previous · play/pause · next · repeat.
///
/// Shuffle and repeat are live, controller-driven modes (read from
/// [PlaybackState], toggled/cycled through the [PlaybackController]); the active
/// state is shown in the warm accent colour and the button's selected styling.
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
          iconSize: 38,
          onPressed: state.hasPrevious ? controller.skipToPrevious : null,
          icon: const Icon(Icons.skip_previous),
          tooltip: 'Previous',
        ),
        _PlayPauseButton(state: state, controller: controller),
        IconButton(
          iconSize: 38,
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
      iconSize: 24,
      onPressed: () => controller.setShuffleEnabled(!enabled),
      icon: const Icon(Icons.shuffle),
      isSelected: enabled,
      // Recede when off so the transport's centre of gravity stays on the
      // play button; warm accent when on, matching the rest of the app.
      color: enabled
          ? theme.colorScheme.secondary
          : theme.colorScheme.onSurface.withValues(alpha: 0.65),
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
      iconSize: 24,
      onPressed: () => controller.setRepeatMode(mode.next),
      icon: Icon(
        mode == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
      ),
      isSelected: active,
      color: active
          ? theme.colorScheme.secondary
          : theme.colorScheme.onSurface.withValues(alpha: 0.65),
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

/// The dominant control: a large warm-accent circle that toggles play/pause and
/// shows a spinner while the next track resolves/buffers.
///
/// Built by hand (rather than [IconButton.filled]) so it can carry the brand's
/// orange gradient and a soft accent glow — the one intentionally bold, "this is
/// the music" moment on the screen — while keeping an ink ripple on tap.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  static const _gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.accentBright, AppColors.accentDeep],
  );

  @override
  Widget build(BuildContext context) {
    // Only the initial prepare shows the spinner-and-disabled state. A mid-stream
    // re-buffer keeps the (active) pause button so the user stays in control —
    // the calm "Buffering…" hint on Now Playing signals the wait instead.
    final bool loading = state.status == PlaybackStatus.loading;
    final bool playing = state.isPlaying || state.isBuffering;
    final VoidCallback? onTap =
        loading ? null : (playing ? controller.pause : controller.play);

    return Tooltip(
      message: playing ? 'Pause' : 'Play',
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: _gradient,
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withValues(alpha: 0.45),
              blurRadius: 24,
              spreadRadius: -4,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: loading ? _loadingIcon() : _playIcon(playing),
            ),
          ),
        ),
      ),
    );
  }

  Widget _loadingIcon() {
    return const SizedBox.square(
      dimension: 26,
      child: CircularProgressIndicator(
        strokeWidth: 2.5,
        valueColor: AlwaysStoppedAnimation<Color>(AppColors.onAccent),
      ),
    );
  }

  Widget _playIcon(bool playing) {
    return Icon(
      playing ? Icons.pause : Icons.play_arrow,
      size: 40,
      color: AppColors.onAccent,
    );
  }
}
