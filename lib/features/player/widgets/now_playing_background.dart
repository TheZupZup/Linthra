import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../shared/widgets/artwork_image.dart';

/// The full-bleed backdrop behind the now-playing content.
///
/// When artwork is available it shows a heavily blurred, dimmed copy of it so
/// the screen feels like it belongs to the song; otherwise it falls back to a
/// calm accent-tinted gradient. Either way a dark scrim is layered on top so the
/// title, slider, and controls stay legible. Artwork that fails to load quietly
/// drops back to the gradient — the background is decorative and never blocks
/// playback.
class NowPlayingBackground extends StatelessWidget {
  const NowPlayingBackground({required this.artworkUri, super.key});

  final Uri? artworkUri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Uri? uri = artworkUri;
    // The backdrop is expensive to paint (a full-screen 40px gaussian blur) but
    // changes only when the track's artwork changes. A RepaintBoundary gives it
    // its own retained compositing layer so the high-frequency playback updates
    // layered above it — the ~4 Hz progress bar, the equalizer indicator — never
    // re-rasterize the blur. That isolation matters more on 90/120/144 Hz panels,
    // where there are simply more frames in which the cached layer pays off.
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Gradient(theme: theme),
          if (uri != null)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Image(
                image: artworkImageProvider(uri),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // A failed/decoding image leaves just the gradient showing.
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                frameBuilder: (context, child, frame, wasSync) {
                  if (wasSync || frame != null) return child;
                  return const SizedBox.shrink();
                },
              ),
            ),
          // Scrim: darken toward the bottom where the controls live.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.surface.withValues(alpha: 0.30),
                  theme.colorScheme.surface.withValues(alpha: 0.70),
                  theme.colorScheme.surface.withValues(alpha: 0.92),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Gradient extends StatelessWidget {
  const _Gradient({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final surface = theme.colorScheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              theme.colorScheme.primary.withValues(alpha: 0.32),
              surface,
            ),
            surface,
            Color.alphaBlend(
              theme.colorScheme.secondary.withValues(alpha: 0.12),
              surface,
            ),
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}
