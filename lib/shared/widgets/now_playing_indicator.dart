import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small, subtle "now playing" marker for track rows.
///
/// While playback is playing it animates as an equalizer — a few accent-coloured
/// bars rising and falling; while paused it shows the same bars at rest, static.
/// It uses Linthra's warm "live" accent so it reads natively as the active track.
///
/// It stays cheap by design: a single [AnimationController] drives one
/// [CustomPainter] (a single repaint boundary), and that controller only runs
/// while [animating] — and never when the platform or user asks for reduced
/// motion ([MediaQueryData.disableAnimations]). So a paused, off-screen, or
/// reduce-motion indicator costs no frames and no battery.
///
/// Pass [overlay] (with a [borderRadius] matching the artwork) to lay it over an
/// album thumbnail: it then fills its parent and paints a subtle scrim behind the
/// centred bars so they stay legible on bright covers and in either theme.
/// Without [overlay] it is just the bars at [size], for inline use.
class NowPlayingIndicator extends StatefulWidget {
  const NowPlayingIndicator({
    required this.animating,
    this.size = 18,
    this.color,
    this.overlay = false,
    this.borderRadius,
    super.key,
  });

  /// Whether playback is actively playing. The bars animate only when this is
  /// true *and* motion is allowed; otherwise they are static.
  final bool animating;

  /// The edge length of the painted equalizer. When [overlay] is set the scrim
  /// fills the parent and the bars are centred at this size.
  final double size;

  /// The bar colour. Defaults to the app's "live" accent.
  final Color? color;

  /// Lay the indicator over artwork: fill the parent and paint a scrim behind the
  /// centred bars for contrast.
  final bool overlay;

  /// The scrim's corner radius, to match the artwork it covers. Only used when
  /// [overlay] is set.
  final BorderRadius? borderRadius;

  @override
  State<NowPlayingIndicator> createState() => _NowPlayingIndicatorState();
}

class _NowPlayingIndicatorState extends State<NowPlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncController();
  }

  @override
  void didUpdateWidget(NowPlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animating != widget.animating) _syncController();
  }

  /// Run the loop only while playing and motion is allowed; otherwise stop it so
  /// a paused or reduce-motion indicator schedules no frames.
  void _syncController() {
    if (widget.animating && !_reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool animate = widget.animating && !_reduceMotion;
    final Widget bars = SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _EqualizerPainter(
          animation: _controller,
          animate: animate,
          color: widget.color ?? Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
    final Widget content = widget.overlay
        ? SizedBox.expand(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: widget.borderRadius,
              ),
              child: Center(child: bars),
            ),
          )
        : bars;
    return Semantics(
      label: widget.animating ? 'Now playing' : 'Now playing, paused',
      child: content,
    );
  }
}

/// Paints the equalizer bars. When [animate] is true it reads [animation] each
/// frame for a smooth, looping, per-bar phase-shifted motion; when false it draws
/// a fixed resting silhouette so a paused marker still reads as an equalizer.
class _EqualizerPainter extends CustomPainter {
  _EqualizerPainter({
    required this.animation,
    required this.animate,
    required this.color,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool animate;
  final Color color;

  /// The static (paused) heights, centre bar tallest, as fractions of height.
  /// Its length is the number of bars drawn.
  static const List<double> _restingHeights = <double>[0.5, 0.85, 0.65];

  static int get _barCount => _restingHeights.length;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t = animate ? animation.value : 0.0;
    // Bars and the gaps between them share one width unit; a gap is a fraction of
    // a bar so the cluster stays balanced at any [size].
    const double gapRatio = 0.55;
    final double unit = size.width / (_barCount + (_barCount - 1) * gapRatio);
    final double barWidth = unit;
    final double gap = unit * gapRatio;
    final double radius = barWidth / 2;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (int i = 0; i < _barCount; i++) {
      final double fraction =
          animate ? _animatedFraction(i, t) : _restingHeights[i];
      final double barHeight = size.height * fraction;
      final double left = i * (barWidth + gap);
      final double top = size.height - barHeight;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(left, top, barWidth, barHeight),
          topLeft: Radius.circular(radius),
          topRight: Radius.circular(radius),
        ),
        paint,
      );
    }
  }

  /// A smooth, looping height in `[0.2, 1.0]` for bar [i], phase-shifted per bar
  /// so the bars don't rise and fall in lockstep.
  double _animatedFraction(int i, double t) {
    final double phase = i * (2 * math.pi / _barCount);
    final double wave = math.sin(t * 2 * math.pi + phase);
    return 0.2 + (wave + 1) / 2 * 0.8;
  }

  @override
  bool shouldRepaint(_EqualizerPainter oldDelegate) =>
      oldDelegate.animate != animate || oldDelegate.color != color;
}
