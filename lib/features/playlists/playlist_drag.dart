import 'package:flutter/material.dart';

import '../../core/models/playlist.dart';
import '../../core/models/track.dart';
import 'playlist_add.dart';

/// The tracks a drag is carrying.
///
/// Resolved lazily, and once. A row cannot work out "the current selection"
/// eagerly at build time: with a 200k-track library that is an O(n) walk per
/// row on every rebuild, so the list would resolve the selection a hundred
/// thousand times to draw one screen. The closure runs when a drop target
/// first asks, which is at most once per drag.
class PlaylistDragPayload {
  PlaylistDragPayload(this._resolve);

  final List<Track> Function() _resolve;
  List<Track>? _resolved;

  List<Track> get tracks => _resolved ??= List<Track>.unmodifiable(_resolve());
}

/// What a drag starting on [track] should carry.
///
/// The whole selection when the row is part of one, otherwise the row alone.
/// Dragging an *unselected* row while a selection is running carries that row
/// by itself, which is what every desktop list does: the drag is about the row
/// under the pointer, not about what happens to be ticked elsewhere.
///
/// [selection] is a callback because a row must not resolve "the current
/// selection" on every build. It is called at most once, when a drag starts.
List<Track> dragPayloadFor({
  required Track track,
  required bool selectionActive,
  required bool selected,
  required List<Track> Function()? selection,
}) {
  if (selectionActive && selected && selection != null) {
    final List<Track> tracks = selection();
    // An empty answer means the selection no longer holds this row (it was
    // filtered out, or removed). Dragging nothing would be worse than dragging
    // the row the pointer is actually on.
    if (tracks.isNotEmpty) return tracks;
  }
  return <Track>[track];
}

/// How a drop target should draw itself while a drag is over it.
enum PlaylistDropState {
  /// Nothing is hovering.
  idle,

  /// A drop here would add something.
  accepted,

  /// A drop here would be refused, because the playlist cannot take these
  /// tracks. Drawn differently rather than not drawn at all: a target that
  /// simply stays inert leaves the user to guess why nothing happened.
  refused,
}

/// Makes [child] draggable onto a playlist, on desktop only.
///
/// Mobile is untouched (#389 is a desktop issue, and the acceptance criteria
/// ask for mobile playlist behaviour to stay as it is). On a phone the row's
/// long-press already starts multi-select, and a second long-press gesture
/// competing for it would break that.
///
/// The drag is horizontally-affine: a vertical drag still scrolls the list, and
/// only a sideways pull starts a drag. That is both what keeps a long track
/// list usable with a mouse and, conveniently, the direction the navigation
/// rail is in.
class PlaylistTrackDraggable extends StatelessWidget {
  const PlaylistTrackDraggable({
    required this.tracks,
    required this.child,
    super.key,
  });

  /// The tracks this drag carries, resolved only if a drag actually starts.
  final List<Track> Function() tracks;

  final Widget child;

  /// Whether a pointer drag should start a playlist drag on this platform.
  static bool isSupported(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isSupported(context)) return child;
    // One payload for the drag, shared with the feedback card, so the whole
    // gesture resolves the selection exactly once.
    final PlaylistDragPayload payload = PlaylistDragPayload(tracks);
    return Draggable<PlaylistDragPayload>(
      data: payload,
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      // The feedback belongs to the root overlay, not the one the drag started
      // in. Each navigation branch has its own overlay, and the spring's whole
      // job is to switch branches mid-drag: the source branch then goes
      // offstage and takes a branch-owned feedback card with it, leaving the
      // pointer carrying an invisible drag to a target it cannot see.
      rootOverlay: true,
      feedback: _DragFeedback(payload: payload),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }
}

/// The little card that follows the cursor during a drag.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.payload});

  final PlaylistDragPayload payload;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Built once, when the drag starts, and reading the same cached payload
    // the drop targets read.
    final List<Track> dragged = payload.tracks;
    final String label =
        dragged.length == 1 ? dragged.single.title : '${dragged.length} songs';
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.playlist_add, size: 18),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A region that takes tracks dropped on it and adds them to [playlist].
///
/// It always accepts the drop, even when the playlist cannot take the tracks,
/// and then says why. Refusing at `onWillAccept` would make the drag bounce
/// back with no explanation at all, which is a worse answer than "only
/// Jellyfin tracks can be added to this playlist".
///
/// Nothing is written for a refused drop: [onDrop] is only called with tracks
/// the playlist accepts, so an unsupported drop cannot touch the playlist's
/// `updatedAt` or queue a sync.
class PlaylistDropRegion extends StatelessWidget {
  const PlaylistDropRegion({
    required this.playlist,
    required this.onDrop,
    required this.builder,
    this.onRefused,
    super.key,
  });

  final Playlist playlist;

  /// Called with the whole dropped selection when the playlist accepts some of
  /// it. Working out which tracks are new is [PlaylistAddPlan]'s job, not the
  /// caller's.
  final void Function(List<Track> tracks) onDrop;

  /// Called instead of [onDrop] when the playlist can take none of them, with
  /// the reason to show.
  final void Function(String message)? onRefused;

  final Widget Function(BuildContext context, PlaylistDropState state) builder;

  @override
  Widget build(BuildContext context) {
    return DragTarget<PlaylistDragPayload>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (DragTargetDetails<PlaylistDragPayload> details) {
        final List<Track> dropped = details.data.tracks;
        final PlaylistAddPlan plan =
            PlaylistAddPlan.of(playlist: playlist, tracks: dropped);
        if (!plan.accepts) {
          final String? message = plan.refusalMessage;
          if (message != null) onRefused?.call(message);
          return;
        }
        onDrop(dropped);
      },
      builder: (
        BuildContext context,
        List<PlaylistDragPayload?> candidate,
        List<dynamic> rejected,
      ) {
        return builder(context, _stateFor(candidate));
      },
    );
  }

  /// Which of the three states the hovering payload (if any) puts this target
  /// in. `candidate` holds the payloads `onWillAccept` said yes to, which is
  /// all of them, so the accept/refuse split happens here.
  PlaylistDropState _stateFor(List<PlaylistDragPayload?> candidate) {
    if (candidate.isEmpty) return PlaylistDropState.idle;
    for (final PlaylistDragPayload? payload in candidate) {
      if (payload == null) continue;
      final PlaylistAddPlan plan =
          PlaylistAddPlan.of(playlist: playlist, tracks: payload.tracks);
      if (plan.accepts) return PlaylistDropState.accepted;
    }
    return PlaylistDropState.refused;
  }
}

/// The standard highlight for a playlist drop target: a tinted, outlined box
/// while a drop would land, an error-tinted one while it would be refused.
///
/// Shared so every playlist target looks the same to a user mid-drag, rather
/// than each inventing its own hint.
///
/// Drawn with a foreground painter rather than a `DecoratedBox`. A decorated
/// ancestor between a `Material` and a `ListTile` hides the tile's background
/// and swallows its ink splashes, and Flutter asserts about it either way
/// round; a painter adds no ancestor and no layout at all, so a highlighted
/// row is the same row it was.
class PlaylistDropHighlight extends StatelessWidget {
  const PlaylistDropHighlight({
    required this.state,
    required this.child,
    super.key,
  });

  final PlaylistDropState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (state == PlaylistDropState.idle) return child;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return CustomPaint(
      foregroundPainter: _DropHighlightPainter(
        accent:
            state == PlaylistDropState.accepted ? colors.primary : colors.error,
      ),
      child: child,
    );
  }
}

class _DropHighlightPainter extends CustomPainter {
  const _DropHighlightPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect box = RRect.fromRectAndRadius(
      // Inset by the stroke so the outline sits inside the row rather than
      // half over its neighbour.
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      const Radius.circular(8),
    );
    canvas
      ..drawRRect(box, Paint()..color = accent.withValues(alpha: 0.10))
      ..drawRRect(
        box,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
  }

  @override
  bool shouldRepaint(_DropHighlightPainter oldDelegate) =>
      oldDelegate.accent != accent;
}
