import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/album.dart';
import '../../player/widgets/album_artwork.dart';

/// One row in the Albums list: cover (or the shared placeholder), album title,
/// and an artist • track-count subtitle. Long titles/artists ellipsize so a row
/// never overflows on a narrow phone.
class AlbumTile extends StatelessWidget {
  const AlbumTile({required this.album, this.onTap, super.key});

  final Album album;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      leading: SizedBox.square(
        dimension: 48,
        child: AlbumArtwork(
          artworkUri: album.artworkUri,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
        ),
      ),
      title: Text(
        album.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        _subtitle(album),
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

  static String _subtitle(Album album) {
    final String count = _countLabel(album.trackCount);
    final String? artist = album.artistName;
    if (artist == null || artist.isEmpty) return count;
    return '$artist • $count';
  }

  static String _countLabel(int count) =>
      count == 1 ? '1 song' : '$count songs';
}
