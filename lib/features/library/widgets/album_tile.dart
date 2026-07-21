import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/catalog/library_grouping.dart';
import '../../../core/models/album.dart';
import '../../player/widgets/album_artwork.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../unified_library_providers.dart';

/// One row in the Albums list: cover (or the shared placeholder), album title,
/// and an artist • track-count subtitle. Long titles/artists ellipsize so a row
/// never overflows on a narrow phone.
///
/// A tap opens the album detail. A long-press opens the shared bulk playlist
/// sheet with every track from this album, preserving album order and the
/// existing duplicate/source safeguards in the playlist flow.
class AlbumTile extends ConsumerWidget {
  const AlbumTile({required this.album, this.onTap, super.key});

  final Album album;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      onLongPress: () => _addAllToPlaylist(context, ref),
    );
  }

  void _addAllToPlaylist(BuildContext context, WidgetRef ref) {
    final tracks = tracksForAlbum(
      ref.read(libraryUnifiedTracksProvider),
      album.id,
    );
    if (tracks.isNotEmpty) {
      showAddToPlaylistSheet(context, tracks);
    }
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
