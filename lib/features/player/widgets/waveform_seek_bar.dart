import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/dimens.dart';

/// A seekable progress bar drawn as a soft waveform — the played portion in the
/// live accent, the rest dimmed — with elapsed and remaining labels beneath it.
///
/// It keeps a real [Slider] underneath (the waveform is painted by a custom
/// [SliderTrackShape]), so it stays fully accessible and drag/tap-to-seek work
/// exactly as before: while dragging, the thumb and the elapsed label follow the
/// finger and [onSeek] fires once on release. Robust to an unknown duration —
/// the bar sits stable and disabled, and the remaining time reads `--:--`.
class WaveformSeekBar extends StatefulWidget {
  const WaveformSeekBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    this.compact = false,
    super.key,
  });

  final Duration position;
  final Duration duration;

  /// Called with the target position when a seek completes. The bar still
  /// renders progress when this is null, just without seeking.
  final ValueChanged<Duration>? onSeek;

  /// A slimmer variant for the lyrics page's bottom strip.
  final bool compact;

  @override
  State<WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<WaveformSeekBar> {
  /// The in-progress drag position in milliseconds, or null when not dragging.
  double? _dragMs;

  void _onChanged(double value) => setState(() => _dragMs = value);

  void _onChangeEnd(double value) {
    widget.onSeek?.call(Duration(milliseconds: value.round()));
    setState(() => _dragMs = null);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int totalMs = widget.duration.inMilliseconds;
    final bool hasDuration = totalMs > 0;
    final bool canSeek = hasDuration && widget.onSeek != null;

    final int posMs = hasDuration
        ? widget.position.inMilliseconds.clamp(0, totalMs).toInt()
        : 0;
    final double sliderValue = _dragMs ?? posMs.toDouble();
    final int elapsedMs = (_dragMs ?? posMs.toDouble()).round();
    final int remainingMs = (totalMs - elapsedMs).clamp(0, totalMs).toInt();

    final Color active = theme.colorScheme.secondary;
    final Color inactive = theme.colorScheme.onSurface.withValues(alpha: 0.18);

    final TextStyle? labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      letterSpacing: 0.3,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: widget.compact ? 18 : 24,
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
            thumbColor: active,
            overlayColor: active.withValues(alpha: 0.14),
            trackShape: _WaveformTrackShape(
              activeColor: active,
              inactiveColor: inactive,
              amplitude: widget.compact ? 5 : 7,
            ),
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: widget.compact ? 5 : 6,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: sliderValue.clamp(0, hasDuration ? totalMs : 1).toDouble(),
            max: hasDuration ? totalMs.toDouble() : 1.0,
            onChanged: canSeek ? _onChanged : null,
            onChangeEnd: canSeek ? _onChangeEnd : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_format(Duration(milliseconds: elapsedMs)),
                  style: labelStyle),
              Text(
                hasDuration
                    ? '-${_format(Duration(milliseconds: remainingMs))}'
                    : '--:--',
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

/// Paints the seek track as a gentle sine wave: the full width dimmed, then the
/// played portion (left of the thumb) redrawn in the accent colour.
class _WaveformTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  _WaveformTrackShape({
    required this.activeColor,
    required this.inactiveColor,
    required this.amplitude,
  });

  final Color activeColor;
  final Color inactiveColor;
  final double amplitude;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final Rect rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.width <= 0) return;

    final Canvas canvas = context.canvas;
    final double centerY = rect.center.dy;
    final double amp = math.min(amplitude, rect.height / 2 - 1);
    const double wavelength = 13.0;

    final Path wave = Path()..moveTo(rect.left, centerY);
    for (double x = rect.left; x <= rect.right; x += 1.5) {
      final double y =
          centerY + amp * math.sin((x - rect.left) / wavelength * 2 * math.pi);
      wave.lineTo(x, y);
    }

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = inactiveColor;
    canvas.drawPath(wave, stroke);

    // Played portion, clipped to the left of the thumb.
    final double clipRight = thumbCenter.dx.clamp(rect.left, rect.right);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(
      rect.left,
      rect.top - amp,
      clipRight,
      rect.bottom + amp,
    ));
    canvas.drawPath(wave, stroke..color = activeColor);
    canvas.restore();
  }
}
