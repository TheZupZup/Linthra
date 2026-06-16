import 'package:flutter/material.dart';

import '../../../ui_linthra/design_tokens.dart';
import '../../../ui_linthra/now_playing_layout_config.dart';

/// Seekable progress bar showing the current position and total duration.
///
/// Robust to an unknown duration (common at the very start of a stream or for a
/// live source): when [duration] is zero the slider sits stable and disabled and
/// the total reads `--:--`, so the UI never breaks or jumps. While the user
/// drags, the thumb and the elapsed label follow the finger; the actual
/// [onSeek] fires once on release, so playback isn't spammed mid-drag.
class PlaybackProgressBar extends StatefulWidget {
  const PlaybackProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    super.key,
  });

  final Duration position;
  final Duration duration;

  /// Called with the target position when a seek completes. The bar still
  /// renders progress when this is null, just without seeking.
  final ValueChanged<Duration>? onSeek;

  @override
  State<PlaybackProgressBar> createState() => _PlaybackProgressBarState();
}

class _PlaybackProgressBarState extends State<PlaybackProgressBar> {
  /// The in-progress drag position in milliseconds, or null when not dragging.
  double? _dragMs;

  void _onChanged(double value) => setState(() => _dragMs = value);

  void _onChangeEnd(double value) {
    widget.onSeek?.call(Duration(milliseconds: value.round()));
    setState(() => _dragMs = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int totalMs = widget.duration.inMilliseconds;
    final bool hasDuration = totalMs > 0;
    final bool canSeek = hasDuration && widget.onSeek != null;

    final int posMs = hasDuration
        ? widget.position.inMilliseconds.clamp(0, totalMs).toInt()
        : 0;
    final double sliderValue = _dragMs ?? posMs.toDouble();
    final double elapsedMs = _dragMs ?? posMs.toDouble();

    final labelStyle = NowPlayingTextStyles.time(theme);

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: NowPlayingProgressTokens.trackHeight,
            overlayShape: const RoundSliderOverlayShape(
              overlayRadius: NowPlayingProgressTokens.overlayRadius,
            ),
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: NowPlayingProgressTokens.thumbRadius,
            ),
            inactiveTrackColor: theme.colorScheme.onSurface.withValues(
              alpha: NowPlayingOpacityTokens.inactiveProgressTrack,
            ),
          ),
          child: Slider(
            value: sliderValue,
            max: hasDuration ? totalMs.toDouble() : 1.0,
            onChanged: canSeek ? _onChanged : null,
            onChangeEnd: canSeek ? _onChangeEnd : null,
          ),
        ),
        // Snug under the track and aligned to its ends, so the times read as a
        // caption for the bar rather than a separate, floating row.
        Padding(
          padding:
              const EdgeInsets.only(top: NowPlayingLayout.gapProgressToTimes),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _format(Duration(milliseconds: elapsedMs.round())),
                style: labelStyle,
              ),
              Text(
                hasDuration ? _format(widget.duration) : '--:--',
                style: labelStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// `m:ss`, widening to `h:mm:ss` past an hour.
  static String _format(Duration d) {
    final int totalSeconds = d.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final String mm = minutes.toString().padLeft(2, '0');
      return '$hours:$mm:$ss';
    }
    return '$minutes:$ss';
  }
}
