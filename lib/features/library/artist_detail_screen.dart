import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/catalog/library_grouping.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/layout/pane_layout.dart';
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
class ArtistDetailScreen extends ConsumerStatefulWidget {
  const ArtistDetailScreen({required this.artistId, super.key});

  final String artistId;

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  final Set<String> _selectedUris = <String>{};

  bool get _selecting => _selectedUris.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final LibraryState state = ref.watch(libraryControllerProvider);

    if (state.status == LibraryStatus.loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    Artist? artist;
    for (final Artist candidate in ref.watch(libraryArtistsProvider)) {
      if (candidate.id == widget.artistId) {
        artist = candidate;
        break;
      }
    }
    final List<Track> songs = ref.watch(libraryUnifiedTracksProvider);
    final List<Track> tracks = tracksForArtist(songs, widget.artistId);
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

    final Artist resolved = artist;
    final List<Album> albums = albumsForArtist(songs, widget.artistId);
    final List<Track> selected = <Track>[
      for (final Track track in tracks)
        if (_selectedUris.contains(track.uri)) track,
    ];

    final Widget scaffold = Scaffold(
      appBar: _selecting
          ? _selectionAppBar(selected)
          : AppBar(
              title: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: <Widget>[
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add all songs to playlist',
                  onPressed: () => showAddToPlaylistSheet(context, tracks),
                ),
              ],
            ),
      body: AdaptiveLayoutBuilder(
        builder: (
          BuildContext context,
          BoxConstraints constraints,
          WindowSizeClass sizeClass,
        ) {
          if (!_selecting && sizeClass.isAtLeast(WindowSizeClass.expanded)) {
            return SplitPanes(
              fixedWidth: sidePaneWidth,
              fixed: SingleChildScrollView(
                child: _ArtistHeader(
                  artist: resolved,
                  albumCount: albums.length,
                  trackCount: tracks.length,
                  stacked: true,
                  onPlay: () => _play(context, tracks),
                  onShuffle: () => _shuffle(context, tracks),
                ),
              ),
              flexible: _catalogList(albums, tracks),
            );
          }
          return AdaptiveContentWidth(
            child: _singleColumnBody(resolved, albums, tracks),
          );
        },
      ),
    );

    if (!_selecting) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: scaffold,
    );
  }

  Widget _singleColumnBody(
    Artist artist,
    List<Album> albums,
    List<Track> tracks,
  ) {
    return CustomScrollView(
      slivers: <Widget>[
        if (!_selecting)
          SliverToBoxAdapter(
            child: _ArtistHeader(
              artist: artist,
              albumCount: albums.length,
              trackCount: tracks.length,
              onPlay: () => _play(context, tracks),
              onShuffle: () => _shuffle(context, tracks),
            ),
          ),
        ..._catalogSlivers(albums, tracks),
      ],
    );
  }

  Widget _catalogList(List<Album> albums, List<Track> tracks) {
    return CustomScrollView(
      key: const Key('artist_detail_catalog'),
      slivers: _catalogSlivers(albums, tracks),
    );
  }

  List<Widget> _catalogSlivers(List<Album> albums, List<Track> tracks) {
    return <Widget>[
      if (!_selecting) ...<Widget>[
        if (albums.length > 1) ...<Widget>[
          const SliverToBoxAdapter(child: _SectionHeader(label: 'Albums')),
          SliverList.builder(
            itemCount: albums.length,
            itemBuilder: (BuildContext context, int index) {
              final Album album = albums[index];
              return AlbumTile(
                album: album,
                onTap: () => _openAlbum(context, album.id),
              );
            },
          ),
        ],
        const SliverToBoxAdapter(child: _SectionHeader(label: 'Songs')),
      ],
      SliverList.builder(
        itemCount: tracks.length,
        itemBuilder: (BuildContext context, int index) {
          final Track track = tracks[index];
          return TrackTile(
            tracks: tracks,
            index: index,
            selectable: true,
            selectionActive: _selecting,
            selected: _selectedUris.contains(track.uri),
            onSelectStart: () => _enterSelection(track),
            onSelectToggle: () => _toggle(track),
          );
        },
      ),
    ];
  }

  PreferredSizeWidget _selectionAppBar(List<Track> selected) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelection,
      ),
      title: Text('${selected.length} selected'),
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.playlist_add),
          tooltip: 'Add to playlist',
          onPressed:
              selected.isEmpty ? null : () => _addSelectedToPlaylist(selected),
        ),
      ],
    );
  }

  void _enterSelection(Track track) {
    setState(() {
      _selectedUris
        ..clear()
        ..add(track.uri);
    });
  }

  void _toggle(Track track) {
    setState(() {
      if (!_selectedUris.add(track.uri)) {
        _selectedUris.remove(track.uri);
      }
    });
  }

  void _exitSelection() {
    setState(_selectedUris.clear);
  }

  Future<void> _addSelectedToPlaylist(List<Track> selected) async {
    await showAddToPlaylistSheet(context, selected);
    if (mounted) _exitSelection();
  }

  void _openAlbum(BuildContext context, String albumId) {
    context.push(AppRoutes.albumDetailPath(albumId));
  }

  void _play(BuildContext context, List<Track> tracks) {
    ref.read(playbackControllerProvider).playTracks(tracks);
    context.push(AppRoutes.player);
  }

  void _shuffle(BuildContext context, List<Track> tracks) {
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
    this.stacked = false,
  });

  final Artist artist;
  final int albumCount;
  final int trackCount;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final bool stacked;

  static const double _stackedPortraitRadius = 72;

  @override
  Widget build(BuildContext context) {
    final String songs = trackCount == 1 ? '1 song' : '$trackCount songs';
    final String summary = albumCount > 0
        ? '${albumCount == 1 ? '1 album' : '$albumCount albums'} • $songs'
        : songs;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (stacked) ...<Widget>[
            _ArtistPortrait(artist: artist, radius: _stackedPortraitRadius),
            const SizedBox(height: AppSpacing.md),
            _ArtistTitleBlock(
              name: artist.name,
              summary: summary,
              center: true,
            ),
          ] else
            Row(
              children: <Widget>[
                _ArtistPortrait(artist: artist, radius: 36),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _ArtistTitleBlock(
                    name: artist.name,
                    summary: summary,
                  ),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          if (stacked) ...<Widget>[
            FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play all'),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.tonalIcon(
              onPressed: onShuffle,
              icon: const Icon(Icons.shuffle),
              label: const Text('Shuffle all'),
            ),
          ] else
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

class _ArtistPortrait extends StatelessWidget {
  const _ArtistPortrait({required this.artist, required this.radius});

  final Artist artist;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Uri? uri = artist.artworkUri;
    return Center(
      child: CircleAvatar(
        radius: radius,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        backgroundImage: uri == null ? null : artworkImageProvider(uri),
        child: uri == null
            ? Icon(
                Icons.person,
                size: radius,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
              )
            : null,
      ),
    );
  }
}

class _ArtistTitleBlock extends StatelessWidget {
  const _ArtistTitleBlock({
    required this.name,
    required this.summary,
    this.center = false,
  });

  final String name;
  final String summary;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color onSurface = theme.colorScheme.onSurface;
    final TextAlign align = center ? TextAlign.center : TextAlign.start;
    return Column(
      crossAxisAlignment:
          center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          summary,
          textAlign: align,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
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
