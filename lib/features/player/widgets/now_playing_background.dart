import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../app/colors.dart';

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
    return Stack(
      fit: StackFit.expand,
      children: [
        _Gradient(theme: theme),
        if (uri != null)
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Image(
              image: NetworkImage(uri.toString()),
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
              AppColors.brand.withValues(alpha: 0.32),
              surface,
            ),
            surface,
            Color.alphaBlend(
              AppColors.accent.withValues(alpha: 0.12),
              surface,
            ),
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}
