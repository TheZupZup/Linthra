import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Progress drawn along a gentle horizontal wave instead of a flat bar.
///
/// The elapsed part of the track is a soft serpentine line in [activeColor];
/// the remainder is a calm straight line in [inactiveColor], with an optional
/// round marker riding the boundary between them. The wave's amplitude eases to
/// zero at both ends of the elapsed segment, so it grows out of — and settles
/// back into — the flat line rather than looking cut off.
///
/// This widget is purely presentational: it knows about a [value] in `0..1` and
/// nothing about playback, seeking, or `Duration`. That keeps it reusable for
/// any "progress along a line" surface (the now-playing bar, the mini-player's
/// top edge) and keeps the interaction and semantics with the caller — see
/// `WavySeekBar` for the seekable, screen-reader-friendly wrapper.
///
/// **There is deliberately no perpetual animation here.** A wave that drifts
/// forever would repaint the full width of the bar on every frame, on the
/// screen users leave open the longest — the opposite of what a low-end phone
/// wants, and something `docs/features/battery.md` rules out for the rest of the UI. The
/// only motion is a one-shot ease when [active] flips: the wave swells to full
/// [amplitude] while progress is advancing and settles back to a calmer,
/// shallower wave at rest. That transition takes [transitionDuration], then the
/// widget stops scheduling frames entirely, and it is skipped outright when the
/// platform or user asks for reduced motion
/// ([MediaQueryData.disableAnimations]). A bar whose [active] never changes —
/// the mini-player's — costs exactly one paint per position tick.
class WavyProgressIndicator extends StatefulWidget {
  const WavyProgressIndicator({
    required this.value,
    required this.activeColor,
    required this.inactiveColor,
    this.thumbColor,
    this.amplitude = 3.0,
    this.wavelength = 20.0,
    this.strokeWidth = 3.0,
    this.thumbRadius = 0.0,
    this.active = true,
    this.transitionDuration = const Duration(milliseconds: 420),
    super.key,
  })  : assert(amplitude >= 0, 'amplitude must not be negative'),
        assert(wavelength > 0, 'wavelength must be positive'),
        assert(strokeWidth > 0, 'strokeWidth must be positive'),
        assert(thumbRadius >= 0, 'thumbRadius must not be negative');

  /// How far along the line the progress marker sits, from 0 to 1. Values
  /// outside that range are clamped, and a NaN (an unknown duration divided
  /// into itself) is treated as 0, so the line never renders garbage.
  final double value;

  /// The elapsed (wavy) part of the line. Linthra passes the warm "live" accent.
  final Color activeColor;

  /// The remaining (flat) part of the line.
  final Color inactiveColor;

  /// The marker's fill. Defaults to [activeColor]. Only drawn when
  /// [thumbRadius] is greater than zero.
  final Color? thumbColor;

  /// Peak vertical deflection of the wave, in logical pixels. Small on purpose —
  /// this is a texture, not a waveform.
  final double amplitude;

  /// The distance between two wave crests, in logical pixels.
  final double wavelength;

  /// Thickness of both the wavy and the flat line.
  final double strokeWidth;

  /// Radius of the progress marker; 0 draws no marker. The track is inset by
  /// this much at both ends so the marker never clips at 0% or 100%.
  final double thumbRadius;

  /// Whether the wave sits at its full [amplitude]. Callers pass whether the
  /// progress is actually advancing — for playback, whether it is playing.
  ///
  /// At rest the wave eases down to a shallower version of itself rather than
  /// going flat, so the bar keeps its identity while still reading, at a glance,
  /// as stopped.
  final bool active;

  /// How long the swell between the resting and the full wave takes. This is the
  /// only animation the widget ever runs, and it runs once per flip of [active].
  final Duration transitionDuration;

  /// The horizontal padding the painter reserves at each end so a marker of
  /// [thumbRadius] (or a line of [strokeWidth]) stays fully inside the box.
  ///
  /// Exposed so a caller mapping a touch position back to a fraction uses the
  /// exact same geometry the painter drew with.
  static double trackInset({
    required double thumbRadius,
    required double strokeWidth,
  }) =>
      math.max(thumbRadius, strokeWidth / 2);

  @override
  State<WavyProgressIndicator> createState() => _WavyProgressIndicatorState();
}

class _WavyProgressIndicatorState extends State<WavyProgressIndicator>
    with SingleTickerProviderStateMixin {
  /// How deep the wave stays at rest, as a fraction of [amplitude]. Shallow
  /// enough to read as stopped, deep enough to still look like a wave.
  static const double _restingScale = 0.4;

  /// Drives the swell between [_restingScale] and 1. It starts *at* the value
  /// matching the initial [active], so opening a screen never plays a
  /// gratuitous entrance animation — only a genuine flip animates.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.transitionDuration,
    value: widget.active ? 1.0 : 0.0,
  );

  late final Animation<double> _swell = _controller.drive(
    Tween<double>(begin: _restingScale, end: 1.0)
        .chain(CurveTween(curve: Curves.easeOutCubic)),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // A reduce-motion request mid-flight means the swell should just be over.
    if (_reduceMotion && _controller.isAnimating) _settle();
  }

  @override
  void didUpdateWidget(WavyProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionDuration != widget.transitionDuration) {
      _controller.duration = widget.transitionDuration;
    }
    if (oldWidget.active != widget.active) {
      if (_reduceMotion) {
        _settle();
      } else {
        // A one-shot ease that finishes and stops: after it lands the widget
        // schedules no further frames.
        unawaited(
          widget.active ? _controller.forward() : _controller.reverse(),
        );
      }
    }
  }

  /// Jump straight to the target without animating.
  void _settle() => _controller.value = widget.active ? 1.0 : 0.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Its own layer, so a swelling wave never re-rasterizes what it is drawn
    // over — on Now Playing that is the expensive blurred artwork backdrop.
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _WavyProgressPainter(
          swell: _swell,
          value: widget.value,
          activeColor: widget.activeColor,
          inactiveColor: widget.inactiveColor,
          thumbColor: widget.thumbColor ?? widget.activeColor,
          amplitude: widget.amplitude,
          wavelength: widget.wavelength,
          strokeWidth: widget.strokeWidth,
          thumbRadius: widget.thumbRadius,
          textDirection: Directionality.of(context),
        ),
      ),
    );
  }
}

/// Draws the flat remainder, the wavy elapsed segment, and the marker.
///
/// [swell] is both the repaint signal and the multiplier on [amplitude], so the
/// painter follows the swell transition without the widget rebuilding, and stops
/// being asked to repaint the moment that transition lands.
class _WavyProgressPainter extends CustomPainter {
  _WavyProgressPainter({
    required this.swell,
    required this.value,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.amplitude,
    required this.wavelength,
    required this.strokeWidth,
    required this.thumbRadius,
    required this.textDirection,
  }) : super(repaint: swell);

  final Animation<double> swell;
  final double value;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final double amplitude;
  final double wavelength;
  final double strokeWidth;
  final double thumbRadius;
  final TextDirection textDirection;

  /// How far apart the polyline's points are, in logical pixels. Sampling a
  /// straight polyline is far cheaper than fitting curves and, at this step
  /// against a 3px stroke, is visually indistinguishable from a true sine —
  /// which is what keeps this affordable on a low-end phone at 60 Hz.
  static const double _sampleStep = 2.5;

  /// The translucent ring behind the marker, as a multiple of [thumbRadius].
  static const double _haloScale = 1.7;
  static const double _haloAlpha = 0.22;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final double inset = WavyProgressIndicator.trackInset(
      thumbRadius: thumbRadius,
      strokeWidth: strokeWidth,
    );
    final double trackWidth = size.width - inset * 2;
    if (trackWidth <= 0) return;

    final double centerY = size.height / 2;
    final double fraction = _safeFraction(value);
    final double elapsed = trackWidth * fraction;

    // In RTL the line runs right-to-left, so progress grows from the right edge
    // and the wave mirrors with it.
    final bool rtl = textDirection == TextDirection.rtl;
    final double origin = rtl ? size.width - inset : inset;
    final double direction = rtl ? -1.0 : 1.0;
    final double markerX = origin + direction * elapsed;

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // The remainder first, so the accent wave and marker sit on top of it.
    if (elapsed < trackWidth) {
      canvas.drawLine(
        Offset(markerX, centerY),
        Offset(origin + direction * trackWidth, centerY),
        stroke..color = inactiveColor,
      );
    }

    if (elapsed > 0) {
      canvas.drawPath(
        _wavePath(
          origin: origin,
          direction: direction,
          length: elapsed,
          centerY: centerY,
        ),
        stroke..color = activeColor,
      );
    }

    if (thumbRadius > 0) {
      final Paint fill = Paint()..isAntiAlias = true;
      canvas.drawCircle(
        Offset(markerX, centerY),
        thumbRadius * _haloScale,
        fill..color = thumbColor.withValues(alpha: _haloAlpha),
      );
      canvas.drawCircle(
        Offset(markerX, centerY),
        thumbRadius,
        fill..color = thumbColor,
      );
    }
  }

  /// The elapsed segment as a sampled polyline, starting at [origin] and running
  /// [length] pixels in [direction].
  Path _wavePath({
    required double origin,
    required double direction,
    required double length,
    required double centerY,
  }) {
    final Path path = Path()..moveTo(origin, centerY);
    // Ease the amplitude in and out over up to one wavelength at each end (or
    // half the segment when it is shorter than that), so the wave emerges from
    // and returns to the flat line instead of ending mid-crest under the marker.
    final double taper = math.min(wavelength, length / 2);
    for (double d = _sampleStep; d < length; d += _sampleStep) {
      path.lineTo(
        origin + direction * d,
        centerY - _deflection(d, length, taper),
      );
    }
    path.lineTo(
      origin + direction * length,
      centerY - _deflection(length, length, taper),
    );
    return path;
  }

  /// Vertical offset of the wave [d] pixels into a segment of [length], with the
  /// amplitude ramped over [taper] pixels at each end and scaled by the current
  /// [swell].
  double _deflection(double d, double length, double taper) {
    if (amplitude <= 0) return 0;
    final double ramp =
        taper <= 0 ? 1.0 : math.min(1.0, math.min(d, length - d) / taper);
    // A cosine ease on the ramp keeps the transition from flat to wavy smooth
    // rather than visibly kinked where the ramp ends.
    final double eased = (1 - math.cos(ramp * math.pi)) / 2;
    return amplitude *
        swell.value *
        eased *
        math.sin(d / wavelength * 2 * math.pi);
  }

  /// [value] clamped to `0..1`, treating a non-finite value (an unknown
  /// duration) as no progress rather than propagating a NaN into the path.
  static double _safeFraction(double value) {
    if (!value.isFinite) return 0;
    return value.clamp(0.0, 1.0);
  }

  @override
  bool shouldRepaint(_WavyProgressPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor ||
      oldDelegate.thumbColor != thumbColor ||
      oldDelegate.amplitude != amplitude ||
      oldDelegate.wavelength != wavelength ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.thumbRadius != thumbRadius ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.swell != swell;
}
