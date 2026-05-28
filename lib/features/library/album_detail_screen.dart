import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/catalog/library_grouping.dart';
import '../../core/models/album.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/empty_state.dart';
import '../player/player_providers.dart';
import '../player/widgets/album_artwork.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'widgets/track_tile.dart';

/// One album's tracks, in album order, with Play / Shuffle and tap-to-play.
///
/// Reads the same derived grouping the Albums tab uses, so it stays in sync
/// with the catalog: tapping a track plays it and queues the rest of *this
/// album*, never the whole library. Reuses [TrackTile], so per-track actions
/// and download state look identical to the main library.
class AlbumDetailScreen extends ConsumerWidget {
  const AlbumDetailScreen({required this.albumId, super.key});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibraryState state = ref.watch(libraryControllerProvider);

    if (state.status == LibraryStatus.loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Reuse the album grouping the Albums tab already memoized, instead of
    // re-grouping the entire catalog on every build — that O(N) pass (base64
    // key + sort per track) blocked the UI thread for seconds on large
    // libraries when opening a detail page. Only the per-album track list, a
    // single bounded filter, is derived here.
    Album? album;
    for (final Album candidate in ref.watch(libraryAlbumsProvider)) {
      if (candidate.id == albumId) {
        album = candidate;
        break;
      }
    }
    final List<Track> tracks = tracksForAlbum(state.tracks, albumId);
    if (album == null || tracks.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.album_outlined,
          title: 'Album not found',
          message: 'It may have been removed from your library.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: _AlbumHeader(
              album: album,
              trackCount: tracks.length,
              onPlay: () => _play(context, ref, tracks),
              onShuffle: () => _shuffle(context, ref, tracks),
            ),
          ),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) =>
                TrackTile(tracks: tracks, index: index),
          ),
        ],
      ),
    );
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

class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({
    required this.album,
    required this.trackCount,
    required this.onPlay,
    required this.onShuffle,
  });

  final Album album;
  final int trackCount;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color onSurface = theme.colorScheme.onSurface;
    final String count = trackCount == 1 ? '1 song' : '$trackCount songs';
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox.square(
                dimension: 120,
                child: AlbumArtwork(artworkUri: album.artworkUri),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      album.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (album.artistName != null &&
                        album.artistName!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        album.artistName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      count,
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
                  label: const Text('Play'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onShuffle,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
