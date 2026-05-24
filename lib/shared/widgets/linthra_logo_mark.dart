import 'package:flutter/material.dart';

import '../../app/colors.dart';

/// Linthra's brand mark, rendered in-app: four rounded equalizer bars under a
/// single violet→orange gradient, echoing a now-playing visualizer.
///
/// It is the Dart twin of the launcher/store icon (`tool/branding/`), drawn from
/// the same bar proportions and the same two-colour identity, so the brand reads
/// consistently from the home screen into the app. Sizes to a [size]×[size] box;
/// the dark squircle behind it is supplied by the surface it sits on.
class LinthraLogoMark extends StatelessWidget {
  const LinthraLogoMark({this.size = 40, super.key});

  final double size;

  /// Bar heights as fractions of [size], matching the launcher icon mark.
  static const _heights = <double>[0.46, 0.70, 0.56, 0.34];

  @override
  Widget build(BuildContext context) {
    final double barWidth = size * 0.15;
    final double gap = size * 0.085;
    final double radius = barWidth / 2;
    return SizedBox(
      width: size,
      height: size,
      child: ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.brandBright, AppColors.accent],
        ).createShader(rect),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < _heights.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Container(
                width: barWidth,
                height: size * _heights[i],
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
