import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/track.dart';
import '../../../core/repositories/playlist_repository.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../shared/widgets/now_playing_indicator.dart';
import '../../../shared/widgets/reorder_focus_walk.dart';
import '../../../shared/widgets/reorder_handle.dart';
import '../../playlists/widgets/create_playlist_dialog.dart';
import '../now_playing.dart';
import '../player_providers.dart';
import 'album_artwork.dart';

/// Opens the advanced Queue / Up Next manager as a tall bottom sheet.
///
/// It's a sheet (not a route) so it floats over Now Playing without leaving it —
/// browsing the queue never touches playback. The current track keeps playing
/// while the listener reorders, removes, or jumps around the queue.
Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const QueueSheet(),
  );
}

/// The Queue / Up Next manager.
///
/// Hosted two ways. As a modal sheet ([showQueueSheet]) it keeps its own height
/// budget and safe-area inset, the way a sheet has to. As an [embedded] pane —
/// what a desktop-width Now Playing does with it — it fills whatever box the
/// host gives it instead: the pane is already inside the screen's padding, and
/// a sheet's 85%-of-the-window ceiling in a column that is the full window tall
/// would leave a band of dead space under the list.
///
/// Reads the live [PlaybackState] (so it stays current while open) and shows,
/// top to bottom: a header with Save/Clear actions, the played history, the
/// current track, and the reorderable up-next list. Every edit goes through the
/// [PlaybackController] — the same single source of truth the mini-player, Now
/// Playing, Cast, and the media session use — so editing the queue here can
/// never start a second, duplicate playback (local or cast). It only ever holds
/// catalog [Track]s, never a resolved/authenticated stream URL.
class QueueSheet extends ConsumerWidget {
  const QueueSheet({this.embedded = false, super.key});

  /// Whether the host lays this out as a pane rather than a modal sheet.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.watch(playbackControllerProvider);
    // Battery: select only the queue identity (current track + up-next +
    // history), not the whole PlaybackState, so the ~4 Hz position ticks don't
    // rebuild the entire sheet while it's open. The controller reuses the same
    // up-next/history list instances on a position tick (copyWith carries them
    // through), so this record compares equal and the sheet stays put; it
    // rebuilds only on a real queue change — skip, reorder, add, remove, clear,
    // or a track change. The current-track equalizer still animates on
    // play/pause via [_CurrentTile]'s own nowPlayingProvider watch.
    final (Track?, List<Track>, List<Track>) queue = ref.watch(
      playbackStateProvider.select((s) {
        final PlaybackState state = s.valueOrNull ?? controller.state;
        return (state.currentTrack, state.upNext, state.previous);
      }),
    );

    final Track? current = queue.$1;
    final List<Track> upNext = queue.$2;
    final List<Track> history = queue.$3;
    final bool canClear = upNext.isNotEmpty || history.isNotEmpty;
    final bool canSave = current != null;

    final Widget body = Column(
      mainAxisSize: embedded ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.queue_music, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Text('Queue', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                onPressed: canSave ? () => _saveAsPlaylist(context, ref) : null,
                icon: const Icon(Icons.playlist_add),
                tooltip: 'Save queue as playlist',
              ),
              TextButton(
                onPressed: canClear ? controller.clearQueue : null,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Flexible(
          child: current == null
              ? const _EmptyQueue()
              : CustomScrollView(
                  slivers: <Widget>[
                    if (history.isNotEmpty) ...<Widget>[
                      const _SectionLabel(label: 'Previously played'),
                      SliverList.builder(
                        itemCount: history.length,
                        itemBuilder: (context, index) => _HistoryTile(
                          track: history[index],
                          onTap: () => ref
                              .read(playbackControllerProvider)
                              .playFromHistory(index),
                        ),
                      ),
                    ],
                    const _SectionLabel(label: 'Now playing'),
                    SliverToBoxAdapter(
                      child: _CurrentTile(track: current),
                    ),
                    const _SectionLabel(label: 'Up next'),
                    if (upNext.isEmpty)
                      const SliverToBoxAdapter(child: _NothingUpNext())
                    else
                      _UpNextList(tracks: upNext),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: AppSpacing.md),
                    ),
                  ],
                ),
        ),
      ],
    );

    if (embedded) return body;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: body,
      ),
    );
  }

  /// Saves the whole queue (history + current + up-next) as a new **local**
  /// playlist. Deliberately local-only: it never auto-syncs to Jellyfin, so a
  /// queue mixing local and remote tracks can't silently drop the local ones or
  /// push anything to a server (see docs/queue.md). Reuses the shared create
  /// dialog (with sync hidden) so the name prompt matches the rest of the app.
  Future<void> _saveAsPlaylist(
    BuildContext context,
    WidgetRef ref,
  ) async {
    // Both captured before the dialog: embedded in the player's queue pane,
    // this sheet is unmounted the moment the window narrows past the pane's
    // minimum, and a resize while the name prompt is up would otherwise leave
    // the save reaching through a disposed ref on submit.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PlaylistRepository repository = ref.read(playlistRepositoryProvider);
    // Read the freshest full queue at tap time rather than capturing it in
    // build — build now selects only the queue identity (see above), and a save
    // is a one-off action, not a hot path.
    final PlaybackState state = ref.read(playbackControllerProvider).state;
    final List<Track> tracks = <Track>[
      ...state.previous,
      if (state.currentTrack != null) state.currentTrack!,
      ...state.upNext,
    ];
    if (tracks.isEmpty) return;

    final PlaylistEdit? edit = await showCreatePlaylistDialog(context);
    if (edit == null) return;

    final Playlist created = await repository.createPlaylist(
      edit.name,
      description: edit.description,
      source: PlaylistSource.local,
    );
    await repository.addTracks(
      created.id,
      <String>[for (final Track track in tracks) track.uri],
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          tracks.length == 1
              ? 'Saved 1 song to “${edit.name}”.'
              : 'Saved ${tracks.length} songs to “${edit.name}”.',
        ),
      ),
    );
  }
}

/// A small, calm section label (Previously played / Now playing / Up next).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xs,
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

/// The current track row, highlighted with the warm "live" accent so it reads
/// as the one playing now. Its trailing equalizer animates while playback is
/// playing and rests while paused. Non-draggable and non-removable on purpose:
/// the queue manager never yanks the playing track out from under playback.
class _CurrentTile extends ConsumerWidget {
  const _CurrentTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bool isPlaying =
        ref.watch(nowPlayingProvider.select((n) => n.isPlaying));
    final String? artist = track.artistName;
    return ListTile(
      leading: SizedBox.square(
        dimension: 44,
        child: AlbumArtwork(
          artworkUri: track.artworkUri,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.secondary,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: artist == null || artist.isEmpty
          ? null
          : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: NowPlayingIndicator(animating: isPlaying),
    );
  }
}

/// An already-played track. Tapping it steps back to that point in the queue.
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.track, required this.onTap});

  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String? artist = track.artistName;
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: SizedBox.square(
        dimension: 40,
        child: Opacity(
          opacity: 0.6,
          child: AlbumArtwork(
            artworkUri: track.artworkUri,
            borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
          ),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
      subtitle: artist == null || artist.isEmpty
          ? null
          : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// The reorderable "Up next" list.
///
/// Stateful for one reason: keyboard reordering. A pointer drag carries the row
/// under the pointer, so the framework keeps the gesture aimed at the right
/// track by itself. A keyboard move is a jump instead — the list rebuilds with
/// the moved track a row away — so focus has to be handed to the row it landed
/// on, or a second Ctrl+Arrow would move whatever slid into the old position.
///
/// The focus nodes are per *position*, not per track, which is what makes that
/// work: after the rebuild the node at the destination index is the moved
/// track's handle. Keying them by track would mean a new node per queue edit,
/// and a duplicate node whenever the same song is queued twice.
class _UpNextList extends ConsumerStatefulWidget {
  const _UpNextList({required this.tracks});

  final List<Track> tracks;

  @override
  ConsumerState<_UpNextList> createState() => _UpNextListState();
}

class _UpNextListState extends ConsumerState<_UpNextList> {
  final ReorderFocusWalk _walk =
      ReorderFocusWalk(debugLabelPrefix: 'queue-handle');

  @override
  void didUpdateWidget(_UpNextList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reorder always produces a new list, so a changed identity means the
    // rows now carry post-move indices and the walk state has served its turn.
    if (!identical(widget.tracks, oldWidget.tracks)) _walk.reset();
  }

  @override
  void dispose() {
    _walk.dispose();
    super.dispose();
  }

  /// Moves the up-next track at [from] to [to] (both 0-based into up-next,
  /// [to] being the destination after removal — the index a normalised
  /// reorderable list reports, and the one [PlaybackQueue.reorderUpNext] takes).
  ///
  /// Out-of-range moves are dropped here as well as in the queue model, so a
  /// keyboard press at either end of the list, or an index left stale by a
  /// queue that changed under the open sheet, is simply harmless.
  bool _move(int from, int to) {
    final int count = widget.tracks.length;
    if (from < 0 || from >= count) return false;
    if (to < 0 || to >= count || to == from) return false;
    ref.read(playbackControllerProvider).reorderQueue(from, to);
    return true;
  }

  /// Moves the track the handle on row [rowIndex] belongs to by [delta]
  /// positions — the keyboard and screen-reader route.
  void _moveBy(int rowIndex, int delta) {
    final int from = _walk.sourceFor(rowIndex);
    final int to = from + delta;
    if (!_move(from, to)) return;
    _walk.recordMove(rowIndex: rowIndex, to: to);
    _walk.followTo(to, delta);
  }

  /// Applies a pointer drop, carrying keyboard focus along with the row that
  /// held it.
  ///
  /// Focus nodes are per position, so a drag changes which track the focused
  /// node belongs to. Left alone, a Ctrl+Arrow after a drag reorders whichever
  /// neighbour slid under the focus rather than the track just dropped. The
  /// remap covers any focused row, not only the dragged one: a drag past a
  /// focused row shifts that row too.
  ///
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
    return SliverReorderableList(
      itemCount: tracks.length,
      onReorderItem: _moveByPointer,
      proxyDecorator: liftedReorderProxy,
      itemBuilder: (context, index) => _UpNextTile(
        // Index-qualified so the same track queued twice never produces a
        // duplicate key (which would crash the reorderable list).
        key: ValueKey<String>('queue-$index-${tracks[index].id}'),
        track: tracks[index],
        index: index,
        count: tracks.length,
        handleFocusNode: _walk.nodeAt(index),
        onPlay: () => ref.read(playbackControllerProvider).playFromQueue(index),
        onRemove: () =>
            ref.read(playbackControllerProvider).removeFromQueue(index),
        onMoveBy: (int delta) => _moveBy(index, delta),
      ),
    );
  }
}

/// An upcoming track: tap to play now, an X to remove it from the queue, and a
/// drag handle to reorder. Removing only drops the queue entry — it never
/// deletes the track from the library or its offline copy.
class _UpNextTile extends StatelessWidget {
  const _UpNextTile({
    required this.track,
    required this.index,
    required this.count,
    required this.handleFocusNode,
    required this.onPlay,
    required this.onRemove,
    required this.onMoveBy,
    super.key,
  });

  final Track track;
  final int index;
  final int count;
  final FocusNode handleFocusNode;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  /// Moves this row by [delta] positions (-1 up, +1 down).
  final ValueChanged<int> onMoveBy;

  @override
  Widget build(BuildContext context) {
    final String? artist = track.artistName;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        onTap: onPlay,
        leading: SizedBox.square(
          dimension: 44,
          child: AlbumArtwork(
            artworkUri: track.artworkUri,
            borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
          ),
        ),
        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: artist == null || artist.isEmpty
            ? null
            : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Remove from queue',
              onPressed: onRemove,
            ),
            ReorderHandle(
              index: index,
              count: count,
              focusNode: handleFocusNode,
              onMoveBy: onMoveBy,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown under "Up next" when the queue holds only the current track.
class _NothingUpNext extends StatelessWidget {
  const _NothingUpNext();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Text(
        'Nothing up next. Use “Play next” or “Add to queue” from any song.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

/// The whole-sheet empty state: nothing is playing at all.
class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.queue_music_outlined,
            size: 40,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Nothing playing', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Pick a track to start a queue.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
