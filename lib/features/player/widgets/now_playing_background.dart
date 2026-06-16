import 'package:flutter/material.dart';

import '../player_theme.dart';

/// The full-bleed backdrop behind the now-playing content.
///
/// A calm, soft-light wash: a light lavender-to-pale-lavender vertical gradient
/// with a faint halo of the brand lavender near the top, so the screen feels
/// gently branded and premium without the heavy, dark, blurred artwork of the
/// old player. It is purely decorative — text and controls sit on solid,
/// high-contrast ink above it.
class NowPlayingBackground extends StatelessWidget {
  const NowPlayingBackground({super.key});

  @override
  Widget build(BuildContext context) {
    // Cheap to paint and constant, so its own retained layer keeps the
    // high-frequency progress updates above it from re-rasterizing the gradient.
    return const RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  PlayerPalette.background,
                  PlayerPalette.background,
                  PlayerPalette.backgroundLow,
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.75),
                radius: 1.1,
                colors: [
                  Color(0x1F8E76D8),
                  Color(0x008E76D8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
