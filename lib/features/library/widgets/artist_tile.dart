import 'package:flutter/material.dart';

import '../../../core/models/artist.dart';
import '../../../shared/widgets/artwork_image.dart';

/// One row in the Artists list: a circular avatar (artwork or a placeholder
/// glyph), the artist name, and an album/track-count subtitle. Long names
/// ellipsize so a row never overflows on a narrow phone.
class ArtistTile extends StatelessWidget {
  const ArtistTile({required this.artist, this.onTap, super.key});

  final Artist artist;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      leading: _ArtistAvatar(artworkUri: artist.artworkUri),
      title: Text(
        artist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        _subtitle(artist),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  static String _subtitle(Artist artist) {
    final String songs =
        artist.trackCount == 1 ? '1 song' : '${artist.trackCount} songs';
    if (artist.albumCount <= 0) return songs;
    final String albums =
        artist.albumCount == 1 ? '1 album' : '${artist.albumCount} albums';
    return '$albums • $songs';
  }
}

/// A circular artist avatar: the artwork when present, otherwise a calm tinted
/// circle with a person glyph (the "optional avatar placeholder").
class _ArtistAvatar extends StatelessWidget {
  const _ArtistAvatar({required this.artworkUri});

  final Uri? artworkUri;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Uri? uri = artworkUri;
    return SizedBox.square(
      dimension: 48,
      child: ClipOval(
        child: uri == null
            ? _placeholder(theme)
            : Image(
                image: artworkImageProvider(uri),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _placeholder(theme),
                frameBuilder: (context, child, frame, wasSync) {
                  if (wasSync || frame != null) return child;
                  return _placeholder(theme);
                },
              ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Icon(
        Icons.person,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
      ),
    );
  }
}
