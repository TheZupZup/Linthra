import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../shared/widgets/artwork_image.dart';

/// The single place album artwork is turned into pixels.
///
/// Artwork resolution lives in [artworkImageProvider] (the shared seam): a
/// Jellyfin primary-image URL needs no token (it is built token-free in the
/// track mapper and stored as `Track.artworkUri`) so it loads over the network,
/// while a local file's embedded cover — extracted into Linthra's cache and
/// stored as a `file://` URI — loads from disk. Subsonic and untagged local
/// tracks carry no artwork and show the placeholder below.
///
/// It fills whatever box the parent gives it (wrap in a `SizedBox`/`AspectRatio`
/// to size it) and degrades gracefully: a missing URL, a load error, or a slow
/// fetch all show the same calm placeholder, so the layout never jumps or shows
/// broken-image glyphs — the UI stays beautiful with no artwork at all.
class AlbumArtwork extends StatelessWidget {
  const AlbumArtwork({
    required this.artworkUri,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.md)),
    super.key,
  });

  final Uri? artworkUri;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final Uri? uri = artworkUri;
    if (uri == null) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: const _ArtworkPlaceholder(),
      );
    }
    // This widget fills whatever box it is given (a 48 px row thumbnail and a
    // full-screen cover are the same widget) so the decode bound has to come
    // from the box rather than from a constant. LayoutBuilder is what makes the
    // real extent available before the image is built (#457).
    return ClipRRect(
      borderRadius: borderRadius,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return Image(
            image: artworkImageProvider(
              uri,
              decodeExtent: artworkDecodeExtent(
                context,
                constraints.biggest.longestSide,
              ),
            ),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const _ArtworkPlaceholder(),
            frameBuilder: (context, child, frame, wasSync) {
              if (wasSync || frame != null) return child;
              return const _ArtworkPlaceholder();
            },
          );
        },
      ),
    );
  }
}

/// A calm stand-in shown whenever there is no artwork (or it can't load): a soft
/// surface tint with a centered note glyph, sized to the available box.
class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final double shortest = constraints.biggest.shortestSide;
        final double iconSize = (shortest.isFinite ? shortest : 96.0) * 0.4;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surfaceContainerHighest,
                theme.colorScheme.surfaceContainerHigh,
              ],
            ),
          ),
          child: Center(
            child: Icon(
              Icons.music_note,
              size: iconSize.clamp(20.0, 96.0),
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
        );
      },
    );
  }
}
