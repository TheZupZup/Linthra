import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/catalog/library_grouping.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/artwork_image.dart';
import '../../shared/widgets/empty_state.dart';
import '../player/player_providers.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'unified_library_providers.dart';
import 'widgets/album_tile.dart';
import 'widgets/track_tile.dart';

/// One artist's catalog: their albums (each opening its album detail) and all
/// their tracks, with Play all / Shuffle all.
///
/// Reads the same derived grouping the Artists tab uses. Playing from here
/// queues only this artist's tracks; tapping a single track queues the artist's
/// tracks from that point. Reuses [TrackTile] and [AlbumTile] so rows match the
/// rest of the library.
class ArtistDetailScreen extends ConsumerWidget {
  const ArtistDetailScreen({required this.artistId, super.key});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibraryState state = ref.watch(libraryControllerProvider);

    if (state.status == LibraryStatus.loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Reuse the artist grouping the Artists tab already memoized, rather than
    // re-grouping the whole catalog on every build (the freeze on large
    // libraries). The per-artist track and album lists below are bounded
    // filters over the catalog, not another full grouping of it.
    Artist? artist;
    for (final Artist candidate in ref.watch(libraryArtistsProvider)) {
      if (candidate.id == artistId) {
        artist = candidate;
        break;
      }
    }
    final List<Track> songs = ref.watch(libraryUnifiedTracksProvider);
    final List<Track> tracks = tracksForArtist(songs, artistId);
    if (artist == null || tracks.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.person_outline,
          title: 'Artist not found',
          message: 'They may have been removed from your library.',
        ),
      );
    }

    final List<Album> albums = albumsForArtist(songs, artistId);

    return Scaffold(
      appBar: AppBar(
        title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add all songs to playlist',
            onPressed: () => showAddToPlaylistSheet(context, tracks),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: _ArtistHeader(
              artist: artist,
              albumCount: albums.length,
              trackCount: tracks.length,
              onPlay: () => _play(context, ref, tracks),
              onShuffle: () => _shuffle(context, ref, tracks),
            ),
          ),
          if (albums.length > 1) ...<Widget>[
            const SliverToBoxAdapter(child: _SectionHeader(label: 'Albums')),
            SliverList.builder(
              itemCount: albums.length,
              itemBuilder: (context, index) {
                final Album album = albums[index];
                return AlbumTile(
                  album: album,
                  onTap: () => _openAlbum(context, album.id),
                );
              },
            ),
          ],
          const SliverToBoxAdapter(child: _SectionHeader(label: 'Songs')),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) =>
                TrackTile(tracks: tracks, index: index),
          ),
        ],
      ),
    );
  }

  void _openAlbum(BuildContext context, String albumId) {
    context.push(AppRoutes.albumDetailPath(albumId));
  }

  void _play(BuildContext context, WidgetRef ref, List<Track> tracks) {
    ref.read(playbackControllerProvider).playTracks(tracks);
    context.push(AppRoutes.player);
  }

  void _shuffle(BuildContext context, WidgetRef ref, List<Track> tracks) {
    final controller = ref.read(playbackControllerProvider);
    controller.setShuffleEnabled(true);
    controller.playTracks(tracks);
    context.push(AppRoutes.player);
  }
}

class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({
    required this.artist,
    required this.albumCount,
    required this.trackCount,
    required this.onPlay,
    required this.onShuffle,
  });

  final Artist artist;
  final int albumCount;
  final int trackCount;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color onSurface = theme.colorScheme.onSurface;
    final String songs = trackCount == 1 ? '1 song' : '$trackCount songs';
    final String summary = albumCount > 0
        ? '${albumCount == 1 ? '1 album' : '$albumCount albums'} • $songs'
        : songs;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 36,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                backgroundImage: artist.artworkUri == null
                    ? null
                    : artworkImageProvider(artist.artworkUri!),
                child: artist.artworkUri == null
                    ? Icon(
                        Icons.person,
                        size: 36,
                        color: onSurface.withValues(alpha: 0.35),
                      )
                    : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      artist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      summary,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play all'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onShuffle,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle all'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
