import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/catalog/library_grouping.dart';
import '../../core/models/album.dart';
import '../../core/models/track.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/layout/pane_layout.dart';
import '../../shared/widgets/empty_state.dart';
import '../player/player_providers.dart';
import '../player/widgets/album_artwork.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'track_selection.dart';
import 'unified_library_providers.dart';
import 'widgets/selection_escape_scope.dart';
import 'widgets/track_tile.dart';

/// One album's tracks, in album order, with Play / Shuffle and tap-to-play.
///
/// Reads the same derived grouping the Albums tab uses, so it stays in sync
/// with the catalog: tapping a track plays it and queues the rest of *this
/// album*, never the whole library. Reuses [TrackTile], so per-track actions
/// and download state look identical to the main library. The app-bar playlist
/// action sends every album track through the shared bulk playlist flow.
/// Long-pressing a track starts multi-select so any subset can use that same
/// playlist flow.
class AlbumDetailScreen extends ConsumerStatefulWidget {
  const AlbumDetailScreen({
    required this.albumId,
    this.selection,
    super.key,
  });

  final String albumId;

  /// The selection to work in, when a host owns one.
  ///
  /// As a pushed route the screen keeps its own, and its lifetime is the
  /// route's. As a detail pane it does not get to: the pane is dropped whenever
  /// the window narrows past [listDetailMinWidth], which would reset a
  /// selection the user is in the middle of on an ordinary resize. So the host
  /// that holds *which* album is open holds what is picked inside it too, and
  /// the pane can come and go without losing either.
  final TrackSelection? selection;

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  /// The selection used when no host supplied one.
  final TrackSelection _ownSelection = TrackSelection();

  /// Which songs are picked, and where a Shift-click measures from (#387).
  TrackSelection get _selection => widget.selection ?? _ownSelection;

  bool get _selecting => _selection.isActive;

  @override
  Widget build(BuildContext context) {
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
      if (candidate.id == widget.albumId) {
        album = candidate;
        break;
      }
    }
    final List<Track> tracks = tracksForAlbum(
      ref.watch(libraryUnifiedTracksProvider),
      widget.albumId,
    );
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

    // Bound after the null check so the layout closures below see a non-null
    // album; a promoted local can't be captured by one.
    final Album resolved = album;
    final List<Track> selected = _selection.resolve(tracks);

    final Widget scaffold = Scaffold(
      appBar: _selecting
          ? _selectionAppBar(selected)
          : AppBar(
              title: Text(
                album.title,
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
          // One album is exactly the shape a desktop window has room for: the
          // cover and its actions stay put in a side pane while the track list
          // scrolls beside them, instead of the cover scrolling away off the
          // top of a very tall list. Selection mode drops back to the single
          // column, where the whole width is the list being selected in.
          if (!_selecting && sizeClass.isAtLeast(WindowSizeClass.expanded)) {
            return _twoPaneBody(resolved, tracks);
          }
          return AdaptiveContentWidth(
            child: _singleColumnBody(resolved, tracks),
          );
        },
      ),
    );

    if (!_selecting) return scaffold;
    // Back leaves the selection on a phone; Escape is the desktop's Back, and
    // the rows here take Ctrl and Shift clicks just like the songs list does.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: SelectionEscapeScope(
        selecting: _selecting,
        onEscape: _exitSelection,
        child: scaffold,
      ),
    );
  }

  /// Phones, and any window too narrow for a second pane: the header scrolls
  /// with the tracks, exactly as it always has.
  Widget _singleColumnBody(Album album, List<Track> tracks) {
    return CustomScrollView(
      slivers: <Widget>[
        if (!_selecting)
          SliverToBoxAdapter(
            child: _AlbumHeader(
              album: album,
              trackCount: tracks.length,
              onPlay: () => _play(context, tracks),
              onShuffle: () => _shuffle(context, tracks),
            ),
          ),
        SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (BuildContext context, int index) =>
              _trackTile(tracks, index),
        ),
      ],
    );
  }

  /// Desktop-width composition: a persistent album pane beside the scrolling
  /// track list. Both read the same `tracks` list and the same selection set,
  /// so nothing here duplicates state — it is the single-column body, laid out.
  Widget _twoPaneBody(Album album, List<Track> tracks) {
    return SplitPanes(
      fixedWidth: sidePaneWidth,
      fixed: SingleChildScrollView(
        child: _AlbumHeader(
          album: album,
          trackCount: tracks.length,
          stacked: true,
          onPlay: () => _play(context, tracks),
          onShuffle: () => _shuffle(context, tracks),
        ),
      ),
      flexible: ListView.builder(
        key: const Key('album_detail_tracks'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: tracks.length,
        itemBuilder: (BuildContext context, int index) =>
            _trackTile(tracks, index),
      ),
    );
  }

  Widget _trackTile(List<Track> tracks, int index) {
    final Track track = tracks[index];
    return TrackTile(
      tracks: tracks,
      index: index,
      selectable: true,
      selectionActive: _selecting,
      selected: _selection.contains(track.uri),
      onSelectStart: () => _enterSelection(track),
      onSelectToggle: () => _toggle(track),
      onSelectRange: _extendSelection,
    );
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
    setState(() => _selection.start(track));
  }

  /// Shift-click: everything between the anchor and the clicked row, over the
  /// list that row is actually in.
  void _extendSelection(List<Track> tracks, int index) {
    setState(() => _selection.extendTo(tracks, index));
  }

  void _toggle(Track track) {
    setState(() {
      _selection.toggle(track);
    });
  }

  /// Leaves the selection.
  ///
  /// The clear is not guarded by [mounted], only the rebuild is: a host-owned
  /// selection outlives this screen on purpose (see [AlbumDetailScreen.selection]), so
  /// an action that finishes after a resize took the pane away still has to end
  /// the mode it belongs to. Otherwise widening the window brings back a
  /// selection whose work is already done.
  void _exitSelection() {
    _selection.clear();
    if (mounted) setState(() {});
  }

  Future<void> _addSelectedToPlaylist(List<Track> selected) async {
    await showAddToPlaylistSheet(context, selected);
    _exitSelection();
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

class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({
    required this.album,
    required this.trackCount,
    required this.onPlay,
    required this.onShuffle,
    this.stacked = false,
  });

  final Album album;
  final int trackCount;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  /// Cover above the text rather than beside it. Used by the desktop pane,
  /// which is tall and narrow — the reverse of the phone header's proportions
  /// — so the cover gets the pane's full width instead of a 120 px thumbnail.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final String count = trackCount == 1 ? '1 song' : '$trackCount songs';
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (stacked) ...<Widget>[
            AspectRatio(
              aspectRatio: 1,
              child: AlbumArtwork(artworkUri: album.artworkUri),
            ),
            const SizedBox(height: AppSpacing.md),
            _AlbumTitleBlock(album: album, count: count),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox.square(
                  dimension: 120,
                  child: AlbumArtwork(artworkUri: album.artworkUri),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(child: _AlbumTitleBlock(album: album, count: count)),
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

/// Title, artist and song count. Identical in both header layouts, so the only
/// thing [_AlbumHeader.stacked] changes is where the cover sits.
class _AlbumTitleBlock extends StatelessWidget {
  const _AlbumTitleBlock({required this.album, required this.count});

  final Album album;
  final String count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color onSurface = theme.colorScheme.onSurface;
    final String? artist = album.artistName;
    return Column(
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
        if (artist != null && artist.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(
            artist,
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
    );
  }
}
