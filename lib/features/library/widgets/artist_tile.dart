import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/catalog/library_grouping.dart';
import '../../../core/models/artist.dart';
import '../../../core/models/track.dart';
import '../../../shared/widgets/artwork_image.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../unified_library_providers.dart';

/// One row in the Artists list: avatar, name, album count, and track count.
///
/// A tap opens the artist. A long-press sends every artist track through the
/// shared bulk playlist flow and its existing duplicate/source safeguards.
class ArtistTile extends ConsumerWidget {
  const ArtistTile({required this.artist, this.onTap, super.key});

  final Artist artist;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      onLongPress: () => _addAllToPlaylist(context, ref),
    );
  }

  void _addAllToPlaylist(BuildContext context, WidgetRef ref) {
    final List<Track> tracks = tracksForArtist(
      ref.read(libraryUnifiedTracksProvider),
      artist.id,
    );
    if (tracks.isNotEmpty) {
      showAddToPlaylistSheet(context, tracks);
    }
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

/// A circular artist avatar: artwork when present, otherwise a tinted glyph.
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
