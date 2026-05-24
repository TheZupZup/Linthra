import 'package:flutter/material.dart';

import '../../../app/dimens.dart';

/// The single place album artwork is turned into pixels.
///
/// This is the app's *artwork resolver seam*: every artwork render goes through
/// [_imageProviderFor], so if a source ever needs signed/tokenized image URLs
/// they can be resolved here — at display time — without persisting a token or
/// changing call sites. Today Jellyfin's primary-image URL needs no token
/// (it is built token-free in the track mapper and stored as `Track.artworkUri`)
/// and local tracks carry none, so a plain [NetworkImage] is enough.
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

  static ImageProvider _imageProviderFor(Uri uri) =>
      NetworkImage(uri.toString());

  @override
  Widget build(BuildContext context) {
    final Uri? uri = artworkUri;
    return ClipRRect(
      borderRadius: borderRadius,
      child: uri == null
          ? const _ArtworkPlaceholder()
          : Image(
              image: _imageProviderFor(uri),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const _ArtworkPlaceholder(),
              frameBuilder: (context, child, frame, wasSync) {
                if (wasSync || frame != null) return child;
                return const _ArtworkPlaceholder();
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
