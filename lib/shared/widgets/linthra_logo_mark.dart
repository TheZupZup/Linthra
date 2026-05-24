import 'package:flutter/material.dart';

import '../../app/colors.dart';

/// Linthra's brand mark, rendered in-app: an abstract "L" monogram made of
/// audio — a bold spine + foot form the letter, with a short equalizer
/// crescendo rising from the foot — under a single violet→orange gradient.
///
/// It is the Dart twin of the launcher/store icon (`tool/branding/`), drawn from
/// the same shape proportions and the same two-colour identity, so the brand
/// reads consistently from the home screen into the app. Sizes to a
/// [size]×[size] box; the dark squircle behind it is supplied by the surface it
/// sits on.
class LinthraLogoMark extends StatelessWidget {
  const LinthraLogoMark({this.size = 40, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: const CustomPaint(painter: _LinthraMarkPainter()),
    );
  }
}

/// Paints the mark from the same fractional geometry baked into
/// `tool/branding/generate_icons.py`, so the in-app mark and the launcher icon
/// stay in lockstep. Coordinates are fractions of the paint box.
class _LinthraMarkPainter extends CustomPainter {
  const _LinthraMarkPainter();

  static const _spineCx = 0.17;
  static const _spineHw = 0.095;
  static const _markTop = 0.07;
  static const _markBottom = 0.92;
  static const _footCy = 0.85;
  static const _footHh = 0.06;
  static const _footLeft = 0.17;
  static const _footRight = 0.93;
  static const _tickHw = 0.055;
  static const _tickBottom = 0.79;
  static const _tickCx = [0.46, 0.64, 0.82];
  static const _tickTop = [0.50, 0.33, 0.47];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..isAntiAlias = true
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [AppColors.brandBright, AppColors.accent],
      ).createShader(Rect.fromLTRB(0, _markTop * s, s, _markBottom * s));

    _vbar(canvas, paint, s, _spineCx, _spineHw, _markTop, _markBottom);

    final foot = Rect.fromLTRB(
      _footLeft * s,
      (_footCy - _footHh) * s,
      _footRight * s,
      (_footCy + _footHh) * s,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(foot, Radius.circular(_footHh * s)),
      paint,
    );

    for (var i = 0; i < _tickCx.length; i++) {
      _vbar(canvas, paint, s, _tickCx[i], _tickHw, _tickTop[i], _tickBottom);
    }
  }

  void _vbar(
    Canvas canvas,
    Paint paint,
    double s,
    double cx,
    double hw,
    double top,
    double bottom,
  ) {
    final rect = Rect.fromLTRB(
      (cx - hw) * s,
      top * s,
      (cx + hw) * s,
      bottom * s,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(hw * s)),
      paint,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
