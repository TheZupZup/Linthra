import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/playlist.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_track_actions.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../data/repositories/favorites_repository_provider.dart';
import '../../data/repositories/playlist_repository_provider.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/reorder_focus_walk.dart';
import '../../shared/widgets/reorder_handle.dart';
import '../downloads/collection_download_actions.dart';
import '../library/song_actions.dart';
import '../player/favorites_providers.dart';
import '../player/now_playing.dart';
import '../player/player_providers.dart';
import '../player/widgets/album_artwork.dart';
import '../player/widgets/track_artwork.dart';
import 'playlist_add.dart';
import 'playlist_drag.dart';
import 'playlist_providers.dart';
import 'widgets/add_to_playlist_sheet.dart';
import 'widgets/create_playlist_dialog.dart';

/// A single playlist's tracks, with Play / Shuffle, drag-to-reorder, per-row
/// actions, and multi-select bulk actions. Tapping a row plays the playlist
/// from that track; reordering and removals persist through the repository.
class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({required this.playlistId, super.key});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  final Set<String> _selectedIds = <String>{};
  bool _selecting = false;

  @override
  Widget build(BuildContext context) {
    final Playlist? playlist =
        ref.watch(playlistByIdProvider(widget.playlistId));
    final AsyncValue<PlaylistTracks> tracksAsync =
        ref.watch(playlistTracksProvider(widget.playlistId));

    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.queue_music_outlined,
          title: 'Playlist not found',
          message: 'It may have been deleted.',
        ),
      );
    }

    final PlaylistTracks resolved =
        tracksAsync.valueOrNull ?? PlaylistTracks.empty;
    final List<Track> selected = <Track>[
      for (final Track track in resolved.tracks)
        if (_selectedIds.contains(track.uri)) track,
    ];
    // "Download all" is offered only when something here actually streams from
    // a server: an all-local playlist is already on disk, and the per-track menu
    // hides offline actions for those rows for the same reason.
    final bool canDownloadAll =
        resolved.tracks.any(ref.watch(remoteTrackDownloaderProvider).isRemote);

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop && _selecting) _exitSelection();
      },
      child: Scaffold(
        appBar: _selecting
            ? _selectionAppBar(selected)
            : AppBar(
                title: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: <Widget>[
                  PopupMenuButton<_DetailMenuAction>(
                    tooltip: 'Playlist actions',
                    onSelected: (a) => _runMenu(playlist, a),
                    itemBuilder: (context) =>
                        <PopupMenuEntry<_DetailMenuAction>>[
                      const PopupMenuItem<_DetailMenuAction>(
                        value: _DetailMenuAction.rename,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Rename'),
                        ),
                      ),
                      if (canDownloadAll) ...<PopupMenuEntry<
                          _DetailMenuAction>>[
                        const PopupMenuItem<_DetailMenuAction>(
                          value: _DetailMenuAction.downloadAll,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.download_outlined),
                            title: Text('Download all'),
                          ),
                        ),
                        // Keeps the destructive entry a deliberate reach away
                        // from the new one directly above it.
                        const PopupMenuDivider(),
                      ],
                      const PopupMenuItem<_DetailMenuAction>(
                        value: _DetailMenuAction.delete,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete playlist'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
        // The whole page takes a dropped track (#389), not just the list: the
        // rail's spring can land a drag here rather than on the Playlists tab
        // when this playlist was already open, and an empty playlist is
        // exactly the one somebody wants to drag songs into.
        body: PlaylistDropRegion(
          playlist: playlist,
          onDrop: (List<Track> tracks) => _addDropped(playlist, tracks),
          onRefused: _say,
          builder: (BuildContext context, PlaylistDropState state) {
            return PlaylistDropHighlight(
              state: state,
              child: tracksAsync.when(
                // Every edit — a reorder, a removal — re-runs the uri-to-Track
                // resolution, and a spinner over the list on each one would
                // both flash and tear down the reorder list's focus nodes
                // mid-keyboard walk. Only the genuine first load shows the
                // spinner.
                skipLoadingOnReload: true,
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => const EmptyState(
                  icon: Icons.error_outline,
                  title: "Couldn't load this playlist",
                  message: 'Try again in a moment.',
                ),
                data: (PlaylistTracks data) => _content(playlist, data),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Adds dropped tracks to the open playlist, through the same plan the
  /// "Add to playlist" sheet and the Playlists tab both use.
  Future<void> _addDropped(Playlist playlist, List<Track> tracks) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PlaylistAddPlan plan = await addTracksToPlaylist(
      repository: ref.read(playlistRepositoryProvider),
      playlist: playlist,
      tracks: tracks,
    );
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(plan.resultMessage)));
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _content(Playlist playlist, PlaylistTracks data) {
    if (data.tracks.isEmpty) {
      return EmptyState(
        icon: Icons.queue_music_outlined,
        title: 'No songs yet',
        message: data.missingCount > 0
            ? '${data.missingCount} '
                '${data.missingCount == 1 ? 'song is' : 'songs are'} '
                'no longer in your library.'
            : 'Add songs from your library or the Now Playing screen.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Header(
          onPlay: () => _play(data.tracks),
          onShuffle: () => _shuffle(data.tracks),
        ),
        if (data.missingCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Text(
              '${data.missingCount} '
              '${data.missingCount == 1 ? 'song is' : 'songs are'} '
              'no longer in your library.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
            ),
          ),
        Expanded(
          child: _selecting
              ? _selectionList(data.tracks)
              : _reorderableList(playlist, data),
        ),
      ],
    );
  }

  /// Ties the three list variants below to one saved scroll offset.
  ///
  /// Entering selection swaps a ReorderableListView for a plain ListView, which
  /// mounts a fresh Scrollable and would otherwise drop the user back at the top
  /// of a long playlist (#582). They are different widgets on purpose (a drag
  /// handle has no place in selection mode), so the position is carried across
  /// by PageStorage rather than by keeping one widget alive.
  static const PageStorageKey<String> _listPosition =
      PageStorageKey<String>('playlist_tracks');

  /// The plain checkbox list shown while selecting (no drag-to-reorder).
  Widget _selectionList(List<Track> tracks) {
    return ListView.builder(
      key: _listPosition,
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final Track track = tracks[index];
        final bool selected = _selectedIds.contains(track.uri);
        return ListTile(
          selected: selected,
          leading: SizedBox.square(
            dimension: 44,
            child: AlbumArtwork(
              artworkUri: track.artworkUri,
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadii.sm)),
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _subtitleWidget(track),
          trailing: Checkbox(
            value: selected,
            onChanged: (_) => _toggle(track),
          ),
          onTap: () => _toggle(track),
        );
      },
    );
  }

  /// The default list: drag-to-reorder (when nothing is missing) + per-row menu.
  Widget _reorderableList(Playlist playlist, PlaylistTracks data) {
    final List<Track> tracks = data.tracks;
    // Reorder maps 1:1 to stored ids only when every id resolved; if some are
    // missing, fall back to a plain list so a drag can't scramble the order.
    final bool canReorder = data.missingCount == 0;

    if (!canReorder) {
      return ListView.builder(
        key: _listPosition,
        itemCount: tracks.length,
        itemBuilder: (context, index) => _trackRow(playlist, tracks, index),
      );
    }

    return _ReorderableTrackList(
      key: _listPosition,
      playlistId: playlist.id,
      tracks: tracks,
      rowBuilder: (int index, Widget handle) =>
          _trackRow(playlist, tracks, index, handle: handle),
    );
  }

  Widget _trackRow(
    Playlist playlist,
    List<Track> tracks,
    int index, {
    Widget? handle,
  }) {
    final Track track = tracks[index];
    final NowPlayingRowState? nowPlaying =
        ref.watch(nowPlayingProvider.select((n) => n.stateForRow(track)));
    // Keyed by the provider-namespaced uri so each source's heart is its own.
    final bool isFavorite = ref.watch(isFavoriteProvider(track.uri));
    return ListTile(
      key: ValueKey<String>(track.uri),
      leading: TrackArtwork(
        artworkUri: track.artworkUri,
        nowPlaying: nowPlaying,
        dimension: 44,
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: _subtitleWidget(track),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          PopupMenuButton<_RowAction>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Track actions',
            onSelected: (a) => _runRow(playlist, track, a),
            itemBuilder: (context) => <PopupMenuEntry<_RowAction>>[
              PopupMenuItem<_RowAction>(
                value: _RowAction.toggleFavorite,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isFavorite ? Icons.favorite : Icons.favorite_border,
                  ),
                  title: Text(
                    isFavorite ? 'Remove from favorites' : 'Add to favorites',
                  ),
                ),
              ),
              const PopupMenuItem<_RowAction>(
                value: _RowAction.playNext,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.queue_music),
                  title: Text('Play next'),
                ),
              ),
              const PopupMenuItem<_RowAction>(
                value: _RowAction.addToQueue,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.add_to_queue),
                  title: Text('Add to queue'),
                ),
              ),
              const PopupMenuItem<_RowAction>(
                value: _RowAction.addToPlaylist,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.playlist_add),
                  title: Text('Add to playlist'),
                ),
              ),
              const PopupMenuItem<_RowAction>(
                value: _RowAction.removeFromPlaylist,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.playlist_remove),
                  title: Text('Remove from playlist'),
                ),
              ),
            ],
          ),
          if (handle != null) handle,
        ],
      ),
      onTap: () => _playFrom(tracks, index),
      onLongPress: () => _enterSelection(track),
    );
  }

  PreferredSizeWidget _selectionAppBar(List<Track> selected) {
    final BulkActionAvailability actions =
        bulkActionsFor(selected, inPlaylist: true);
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelection,
      ),
      title: Text('${selected.length} selected'),
      actions: <Widget>[
        if (actions.canAddToPlaylist)
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add to playlist',
            onPressed: selected.isEmpty ? null : () => _addToPlaylist(selected),
          ),
        if (actions.canRemoveFromPlaylist)
          IconButton(
            icon: const Icon(Icons.playlist_remove),
            tooltip: 'Remove from playlist',
            onPressed:
                selected.isEmpty ? null : () => _removeFromPlaylist(selected),
          ),
        if (actions.canRemoveOfflineCopy)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove offline copies',
            onPressed: selected.isEmpty ? null : () => _removeOffline(selected),
          ),
        if (actions.canRemoveFromLibrary)
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Remove from Linthra',
            onPressed:
                selected.isEmpty ? null : () => _removeFromLibrary(selected),
          ),
      ],
    );
  }

  // --- Playback ---------------------------------------------------------

  void _play(List<Track> tracks) {
    if (tracks.isEmpty) return;
    ref.read(playbackControllerProvider).playTracks(tracks);
    context.push(AppRoutes.player);
  }

  void _shuffle(List<Track> tracks) {
    if (tracks.isEmpty) return;
    final controller = ref.read(playbackControllerProvider);
    controller.setShuffleEnabled(true);
    controller.playTracks(tracks);
    context.push(AppRoutes.player);
  }

  void _playFrom(List<Track> tracks, int index) {
    ref.read(playbackControllerProvider).playTracks(tracks, startIndex: index);
    context.push(AppRoutes.player);
  }

  // --- Selection --------------------------------------------------------

  void _enterSelection(Track track) {
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(track.uri);
    });
  }

  void _toggle(Track track) {
    setState(() {
      if (!_selectedIds.add(track.uri)) {
        _selectedIds.remove(track.uri);
      }
      if (_selectedIds.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  // --- Actions ----------------------------------------------------------

  Future<void> _runMenu(Playlist playlist, _DetailMenuAction action) async {
    switch (action) {
      case _DetailMenuAction.rename:
        await _rename(playlist);
      case _DetailMenuAction.downloadAll:
        await _downloadAll(playlist);
      case _DetailMenuAction.delete:
        await _deletePlaylist(playlist);
    }
  }

  Future<void> _runRow(
    Playlist playlist,
    Track track,
    _RowAction action,
  ) async {
    switch (action) {
      case _RowAction.toggleFavorite:
        // Like/unlike from the playlist row without touching playback or the
        // queue. Re-read the current state so the toggle is correct even if the
        // heart changed after the menu opened; the real [Track] uri routes the
        // favourite to the right source (and its Subsonic sync push).
        final bool isFavorite = ref.read(isFavoriteProvider(track.uri));
        await ref
            .read(favoritesRepositoryProvider)
            .setFavorite(track, !isFavorite);
      case _RowAction.playNext:
        ref.read(playbackControllerProvider).playNext(track);
      case _RowAction.addToQueue:
        ref.read(playbackControllerProvider).addToQueue(track);
      case _RowAction.addToPlaylist:
        await showAddToPlaylistSheet(context, <Track>[track]);
      case _RowAction.removeFromPlaylist:
        await _removeOneFromPlaylist(playlist, track);
    }
  }

  Future<void> _rename(Playlist playlist) async {
    final PlaylistEdit? edit = await showRenamePlaylistDialog(
      context,
      initialName: playlist.name,
      initialDescription: playlist.description,
    );
    if (edit == null) return;
    await ref.read(playlistRepositoryProvider).renamePlaylist(
          playlist.id,
          edit.name,
          description: edit.description,
        );
  }

  /// Downloads every song currently in this playlist for offline use, through
  /// the shared collection action (which confirms first and reuses the one
  /// download repository, cache limit and network policy).
  ///
  /// The tracks are read here, when the action is chosen, rather than captured
  /// when the menu was built, so a playlist that changed in between downloads
  /// what it holds now.
  Future<void> _downloadAll(Playlist playlist) async {
    final List<Track> tracks = ref
            .read(playlistTracksProvider(widget.playlistId))
            .valueOrNull
            ?.tracks ??
        const <Track>[];
    if (tracks.isEmpty) return;
    await CollectionDownloadActions.downloadAll(
      context,
      ref,
      label: playlist.name,
      tracks: tracks,
    );
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final NavigatorState navigator = Navigator.of(context);
    final bool confirmed = await showConfirmDialog(
      context,
      title: 'Delete playlist',
      message: 'Delete playlist “${playlist.name}”? This removes the playlist '
          'from Linthra. Synced playlists may also be removed from the server '
          'if sync is enabled.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    await ref.read(playlistRepositoryProvider).deletePlaylist(playlist.id);
    navigator.pop();
  }

  Future<void> _removeOneFromPlaylist(Playlist playlist, Track track) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(playlistRepositoryProvider);
    await repository.removeTrack(playlist.id, track.uri);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Removed “${track.title}” from playlist.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => repository.addTrack(playlist.id, track.uri),
        ),
      ),
    );
  }

  Future<void> _removeFromPlaylist(List<Track> selected) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context,
      title: 'Remove from playlist',
      message: selected.length == 1
          ? 'Remove “${selected.first.title}” from this playlist?'
          : 'Remove ${selected.length} songs from this playlist?',
      confirmLabel: 'Remove',
      destructive: false,
    );
    if (!confirmed) return;
    final repository = ref.read(playlistRepositoryProvider);
    for (final Track track in selected) {
      await repository.removeTrack(widget.playlistId, track.uri);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          selected.length == 1
              ? 'Removed 1 song from playlist.'
              : 'Removed ${selected.length} songs from playlist.',
        ),
      ),
    );
    _exitSelection();
  }

  Future<void> _addToPlaylist(List<Track> selected) async {
    await showAddToPlaylistSheet(context, selected);
    _exitSelection();
  }

  Future<void> _removeFromLibrary(List<Track> selected) async {
    final bool removed = await SongActions.removeFromLibrary(
      context,
      ref,
      selected,
      playlistId: widget.playlistId,
    );
    if (removed) _exitSelection();
  }

  Future<void> _removeOffline(List<Track> selected) async {
    final bool ran =
        await SongActions.removeOfflineCopies(context, ref, selected);
    if (ran) _exitSelection();
  }

  Widget? _subtitleWidget(Track track) {
    final String? subtitle = _subtitle(track);
    if (subtitle == null) return null;
    return Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  String? _subtitle(Track track) {
    final String? artist = track.artistName;
    if (artist == null || artist.isEmpty) return null;
    final String? album = track.albumName;
    return (album == null || album.isEmpty) ? artist : '$artist • $album';
  }
}

/// The playlist's drag-to-reorder list.
///
/// Its own widget for the same reason the queue's Up Next list is: keyboard
/// reordering needs to know when the rows have caught up with a move, and
/// `didUpdateWidget` on a list that is handed its tracks is the honest signal
/// for that. Everything about *how* a row is reordered — the grab cursor, the
/// lift, the Ctrl/Cmd + arrow chord, the screen-reader move actions — lives in
/// the shared [ReorderHandle] and [ReorderFocusWalk], so the playlist editor
/// and the queue cannot drift into two different gestures (#388, #389).
///
/// Every route (drag, chord, screen reader) lands on the same
/// [PlaylistRepository.reorderTracks] call, so there is one persistence path
/// rather than a keyboard copy of one. The repository writes locally first and
/// never throws, so a server that refuses the new order leaves the local order
/// applied and the playlist marked as failed to sync, rather than losing the
/// edit.
class _ReorderableTrackList extends ConsumerStatefulWidget {
  const _ReorderableTrackList({
    required this.playlistId,
    required this.tracks,
    required this.rowBuilder,
    super.key,
  });

  final String playlistId;
  final List<Track> tracks;

  /// Builds the row at an index, handed the reorder handle to put in it.
  final Widget Function(int index, Widget handle) rowBuilder;

  @override
  ConsumerState<_ReorderableTrackList> createState() =>
      _ReorderableTrackListState();
}

class _ReorderableTrackListState extends ConsumerState<_ReorderableTrackList> {
  final ReorderFocusWalk _walk =
      ReorderFocusWalk(debugLabelPrefix: 'playlist-handle');

  @override
  void didUpdateWidget(_ReorderableTrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reorder always resolves to a fresh list, so a changed identity means
    // the rows now carry post-move indices and the walk has served its turn.
    if (!identical(widget.tracks, oldWidget.tracks)) _walk.reset();
  }

  @override
  void dispose() {
    _walk.dispose();
    super.dispose();
  }

  /// Moves the track at [from] to [to], both 0-based into the visible list,
  /// [to] being the destination *after* removal.
  ///
  /// Out-of-range moves are dropped here as well as in the repository, so a
  /// chord at either end of the list — or an index left stale by a playlist
  /// that changed under the open screen — is simply harmless.
  bool _move(int from, int to) {
    final int count = widget.tracks.length;
    if (from < 0 || from >= count) return false;
    if (to < 0 || to >= count || to == from) return false;
    // The repository still takes the legacy pre-removal insertion index, so a
    // downward move is converted at this one boundary and persistence
    // behaviour stays exactly what it was.
    ref.read(playlistRepositoryProvider).reorderTracks(
          widget.playlistId,
          from,
          to > from ? to + 1 : to,
        );
    return true;
  }

  /// The keyboard and screen-reader route: move the track the handle on row
  /// [rowIndex] belongs to by [delta] positions.
  void _moveBy(int rowIndex, int delta) {
    final int from = _walk.sourceFor(rowIndex);
    final int to = from + delta;
    if (!_move(from, to)) return;
    _walk.recordMove(rowIndex: rowIndex, to: to);
    _walk.followTo(to, delta);
  }

  /// A pointer drop, carrying keyboard focus along with the row that held it.
  /// Nothing happens when no handle has focus, so a plain mouse drag never
  /// pulls focus into the list.
  void _moveByPointer(int from, int to) {
    final int focused = _walk.focusedIndex;
    if (!_move(from, to)) return;
    if (focused < 0) return;
    _walk.followTo(
      ReorderFocusWalk.positionAfterMove(focused, from: from, to: to),
      to - from,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Track> tracks = widget.tracks;
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      proxyDecorator: liftedReorderProxy,
      itemCount: tracks.length,
      onReorderItem: _moveByPointer,
      itemBuilder: (BuildContext context, int index) => widget.rowBuilder(
        index,
        ReorderHandle(
          index: index,
          count: tracks.length,
          focusNode: _walk.nodeAt(index),
          onMoveBy: (int delta) => _moveBy(index, delta),
        ),
      ),
    );
  }
}

enum _DetailMenuAction { rename, downloadAll, delete }

enum _RowAction {
  toggleFavorite,
  playNext,
  addToQueue,
  addToPlaylist,
  removeFromPlaylist,
}

class _Header extends StatelessWidget {
  const _Header({required this.onPlay, required this.onShuffle});

  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
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
    );
  }
}
