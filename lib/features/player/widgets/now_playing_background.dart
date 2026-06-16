import 'package:flutter/material.dart';

import '../player_theme.dart';

/// The full-bleed backdrop behind the now-playing content.
///
/// A calm, soft-light wash: a warm cream-to-blush vertical gradient with a faint
/// halo of the live [accent] near the top, so the screen quietly belongs to the
/// song without the heavy, dark, blurred artwork of the old player. It is purely
/// decorative — text and controls sit on solid, high-contrast ink above it.
class NowPlayingBackground extends StatelessWidget {
  const NowPlayingBackground({required this.accent, super.key});

  /// The album-derived (or fallback) accent, woven in faintly at the top.
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // Cheap to paint and changes only when the accent (track) changes, so its
    // own retained layer keeps the high-frequency progress updates above it from
    // re-rasterizing the gradient.
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  PlayerPalette.background,
                  PlayerPalette.background,
                  PlayerPalette.blush,
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.75),
                radius: 1.1,
                colors: [
                  accent.withValues(alpha: 0.14),
                  accent.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
