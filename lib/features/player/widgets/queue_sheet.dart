import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/track.dart';
import '../../../core/repositories/playlist_repository.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../shared/widgets/now_playing_indicator.dart';
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
  final List<FocusNode> _handleFocusNodes = <FocusNode>[];

  /// Where a keyboard walk started from and where it has actually put the
  /// track, while the list catches up.
  ///
  /// The queue reaches this sheet through a stream, so a move is applied to the
  /// queue before any frame rebuilds the rows with it. A held chord repeats
  /// faster than that: the second press is fired by a handle still carrying the
  /// pre-move index, and taking it at face value would move the track back
  /// where it came from. [_walkOrigin] is that stale index, [_walkLanded] is
  /// where the track really is, and both are dropped the moment the rebuild
  /// makes the widgets truthful again.
  int? _walkOrigin;
  int? _walkLanded;

  @override
  void didUpdateWidget(_UpNextList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reorder always produces a new list, so a changed identity means the
    // rows now carry post-move indices and the walk state has served its turn.
    if (!identical(widget.tracks, oldWidget.tracks)) {
      _walkOrigin = null;
      _walkLanded = null;
    }
  }

  @override
  void dispose() {
    for (final FocusNode node in _handleFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// The handle focus node for row [index], grown on demand. The list only ever
  /// grows within one sheet: a shrinking queue leaves spare nodes parked, which
  /// costs nothing and keeps the indices stable.
  FocusNode _focusNodeAt(int index) {
    while (_handleFocusNodes.length <= index) {
      _handleFocusNodes.add(
        FocusNode(debugLabel: 'queue-handle-${_handleFocusNodes.length}'),
      );
    }
    return _handleFocusNodes[index];
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
  ///
  /// [rowIndex] is only a starting point: while a walk is in flight the rows
  /// still report their pre-move indices, so the real source comes from
  /// [_walkLanded]. The substitution is guarded on [_walkOrigin] so a press on
  /// some *other* row inside that same window is still taken at face value.
  void _moveBy(int rowIndex, int delta) {
    final int from = _walkLanded != null && rowIndex == _walkOrigin
        ? _walkLanded!
        : rowIndex;
    final int to = from + delta;
    if (!_move(from, to)) return;
    _walkOrigin = rowIndex;
    _walkLanded = to;
    _followWalkTo(to, delta);
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
    final int focused =
        _handleFocusNodes.indexWhere((FocusNode node) => node.hasFocus);
    if (!_move(from, to)) return;
    if (focused < 0) return;
    _followWalkTo(_positionAfterMove(focused, from: from, to: to), to - from);
  }

  /// Where row [index] ends up once the row at [from] is moved to [to].
  static int _positionAfterMove(
    int index, {
    required int from,
    required int to,
  }) {
    if (index == from) return to;
    if (from < index && index <= to) return index - 1;
    if (to <= index && index < from) return index + 1;
    return index;
  }

  /// Scrolls the moved track's handle into view and gives it focus, so a held
  /// chord keeps walking the same track.
  ///
  /// The scroll is the part that makes this hold up on a long queue. Focus can
  /// only land on a row the sliver has actually built, and a walk that never
  /// scrolls eventually pushes the track past the built range: focus would stay
  /// behind on the row a *different* track just slid into, and the next press
  /// would move that one instead. Keeping the walking row on screen keeps its
  /// destination within the built range, one row at a time.
  void _followWalkTo(int index, int delta) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || index >= _handleFocusNodes.length) return;
      final FocusNode node = _handleFocusNodes[index];
      final BuildContext? handle = node.context;
      if (handle == null) return;
      Scrollable.ensureVisible(
        handle,
        alignmentPolicy: delta > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
      node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Track> tracks = widget.tracks;
    return SliverReorderableList(
      itemCount: tracks.length,
      onReorderItem: _moveByPointer,
      proxyDecorator: _liftedRow,
      itemBuilder: (context, index) => _UpNextTile(
        // Index-qualified so the same track queued twice never produces a
        // duplicate key (which would crash the reorderable list).
        key: ValueKey<String>('queue-$index-${tracks[index].id}'),
        track: tracks[index],
        index: index,
        count: tracks.length,
        handleFocusNode: _focusNodeAt(index),
        onPlay: () => ref.read(playbackControllerProvider).playFromQueue(index),
        onRemove: () =>
            ref.read(playbackControllerProvider).removeFromQueue(index),
        onMoveBy: (int delta) => _moveBy(index, delta),
      ),
    );
  }
}

/// The row being dragged: lifted off the list on a shadow so it reads as picked
/// up rather than merely highlighted. Desktop pointers have no haptics and no
/// long-press wind-up, so this elevation is the only feedback that the drag
/// actually took.
Widget _liftedRow(Widget child, int index, Animation<double> animation) {
  return AnimatedBuilder(
    animation: animation,
    builder: (BuildContext context, Widget? child) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      final double t = Curves.easeInOut.transform(animation.value);
      return Material(
        elevation: t * 6,
        color: Color.lerp(scheme.surface, scheme.surfaceContainerHighest, t),
        shadowColor: scheme.shadow,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: child,
      );
    },
    child: child,
  );
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
            _ReorderHandle(
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

/// The modifier the move chord is spelled with on [platform].
///
/// Both modifiers stay registered everywhere — an unused activator costs
/// nothing — but the hint has to name the one that actually works here. On
/// macOS Ctrl+Arrow belongs to Mission Control and never reaches the app, so a
/// hint saying Ctrl there would point people at a chord the OS eats.
String _moveModifierLabel(TargetPlatform platform) =>
    platform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl';

/// Asks for the focused queue row to move [delta] positions (-1 up, +1 down).
class _MoveQueueItemIntent extends Intent {
  const _MoveQueueItemIntent(this.delta);

  final int delta;
}

/// The reorder affordance on an up-next row: a pointer drag target that is also
/// a real focusable control.
///
/// Dragging is the fast path and stays exactly what it was. The rest is what a
/// drag alone cannot serve: **Ctrl + ↑ / ↓** (Cmd on macOS) moves the focused
/// row without a pointer, and the same two moves are offered as custom
/// semantics actions so a screen reader can reorder the queue too. Both routes
/// run through the same controller call the drag does, so there is one reorder
/// path, not a keyboard copy of one.
///
/// The chord takes a modifier on purpose: a bare arrow inside a scrolling sheet
/// belongs to focus traversal and scrolling, and stealing it would trade one
/// accessible behaviour for another.
class _ReorderHandle extends StatelessWidget {
  const _ReorderHandle({
    required this.index,
    required this.count,
    required this.focusNode,
    required this.onMoveBy,
  });

  final int index;
  final int count;
  final FocusNode focusNode;
  final ValueChanged<int> onMoveBy;

  /// Shortcuts sit *above* the focus node, not inside it: a key event travels
  /// up from the focused node, so a [Shortcuts] below it would never see one.
  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp, control: true):
        _MoveQueueItemIntent(-1),
    SingleActivator(LogicalKeyboardKey.arrowDown, control: true):
        _MoveQueueItemIntent(1),
    SingleActivator(LogicalKeyboardKey.arrowUp, meta: true):
        _MoveQueueItemIntent(-1),
    SingleActivator(LogicalKeyboardKey.arrowDown, meta: true):
        _MoveQueueItemIntent(1),
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canMoveUp = index > 0;
    final bool canMoveDown = index < count - 1;
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MoveQueueItemIntent: CallbackAction<_MoveQueueItemIntent>(
            onInvoke: (_MoveQueueItemIntent intent) {
              onMoveBy(intent.delta);
              return null;
            },
          ),
        },
        // Not a semantics container: the actions merge up into the row's own
        // node, so a screen reader reads one row that happens to be movable
        // rather than a stray control beside it. The ends of the list offer
        // only the move that exists.
        child: Semantics(
          customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
            if (canMoveUp)
              const CustomSemanticsAction(label: 'Move up'): () => onMoveBy(-1),
            if (canMoveDown)
              const CustomSemanticsAction(label: 'Move down'): () =>
                  onMoveBy(1),
          },
          child: Focus(
            focusNode: focusNode,
            child: Builder(
              builder: (BuildContext context) {
                final bool focused = Focus.of(context).hasFocus;
                return MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: ReorderableDragStartListener(
                    index: index,
                    child: Tooltip(
                      message: 'Reorder (drag, or '
                          '${_moveModifierLabel(theme.platform)} + ↑ / ↓)',
                      // Hover only. The default long-press trigger puts a
                      // long-press recognizer in the arena next to the drag
                      // listener, and on a handle the press *is* the drag: the
                      // tooltip wins and the row never lifts. Hover is the
                      // desktop trigger anyway, and the handle is still named
                      // for screen readers either way.
                      triggerMode: TooltipTriggerMode.manual,
                      child: Container(
                        margin: const EdgeInsets.only(left: AppSpacing.xs),
                        padding: const EdgeInsets.all(AppSpacing.xs),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          border: Border.all(
                            width: 2,
                            color: focused
                                ? theme.colorScheme.primary
                                : Colors.transparent,
                          ),
                        ),
                        child: const Icon(
                          Icons.drag_handle,
                          semanticLabel: 'Reorder',
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
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
