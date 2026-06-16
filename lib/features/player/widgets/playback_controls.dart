import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/services/playback_controller.dart';
import '../player_providers.dart';

/// The primary transport row: previous · play/pause · next.
///
/// Previous/next sit in soft rounded containers and reflect the live queue
/// (disabled at the ends); the centre is a large, tactile accent play/pause that
/// forwards straight to the controller and shows a spinner while a track loads.
/// Shuffle and repeat live in the secondary action row (`NowPlayingActions`), so
/// this row stays focused on the three controls a listener reaches for most.
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({required this.state, super.key});

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playbackControllerProvider);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundedTransportButton(
          icon: Icons.skip_previous,
          tooltip: 'Previous',
          onPressed: state.hasPrevious ? controller.skipToPrevious : null,
        ),
        _PlayPauseButton(state: state, controller: controller),
        _RoundedTransportButton(
          icon: Icons.skip_next,
          tooltip: 'Next',
          onPressed: state.hasNext ? controller.skipToNext : null,
        ),
      ],
    );
  }
}

/// Previous/next as a soft tonal container — calm when enabled, faded when the
/// queue has no neighbour in that direction.
class _RoundedTransportButton extends StatelessWidget {
  const _RoundedTransportButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 30,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: theme.colorScheme.surfaceContainerHigh,
        foregroundColor: theme.colorScheme.onSurface,
        disabledBackgroundColor:
            theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.45),
        disabledForegroundColor:
            theme.colorScheme.onSurface.withValues(alpha: 0.28),
        fixedSize: const Size(76, 58),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md + 2),
        ),
      ),
    );
  }
}

/// The dominant control: a large rounded-rect filled with the live accent that
/// toggles play/pause and shows a spinner while the next track resolves/buffers.
///
/// Built by hand (rather than [IconButton.filled]) so it can carry the accent
/// fill and a soft glow — the one intentionally bold, "this is the music" moment
/// on the screen — while keeping an ink ripple on tap.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Only the initial prepare shows the spinner-and-disabled state. A mid-stream
    // re-buffer keeps the (active) pause button so the user stays in control —
    // the calm "Buffering…" hint on Now Playing signals the wait instead.
    final bool loading = state.status == PlaybackStatus.loading;
    final bool playing = state.isPlaying || state.isBuffering;
    final VoidCallback? onTap =
        loading ? null : (playing ? controller.pause : controller.play);

    final Color accent = theme.colorScheme.secondary;
    final Color onAccent = theme.colorScheme.onSecondary;

    return Tooltip(
      message: playing ? 'Pause' : 'Play',
      child: Container(
        width: 78,
        height: 66,
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.36),
              blurRadius: 22,
              spreadRadius: -6,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: loading
                  ? _loadingIcon(onAccent)
                  : Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      size: 38,
                      color: onAccent,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _loadingIcon(Color color) {
    return SizedBox.square(
      dimension: 26,
      child: CircularProgressIndicator(
        strokeWidth: 2.5,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}
