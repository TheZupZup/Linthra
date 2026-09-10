import 'dart:async';

import 'package:flutter/material.dart';

import '../playlists/playlist_drag.dart';

/// Switches to the Playlists tab when a track drag rests over the navigation
/// rail, so a song dragged out of the library can reach a playlist row.
///
/// Without this there is nowhere to drop. The library and the playlist list
/// live in different tabs, and a drag cannot press a navigation button on its
/// way past, which is why every desktop file manager spring-loads its
/// sidebar. Linthra's is the same idea with one destination that means
/// anything mid-drag.
///
/// The whole rail springs, not the Playlists destination alone. Measured, the
/// destination's icon slot is 24x24 inside a 128 px rail: a target that small
/// is a poor thing to ask someone to hit while holding a drag, and the two
/// stray destinations they might cross on the way are not somewhere a track
/// drag could have meant to go anyway. The rail highlights Playlists while a
/// drag is over it, so where the drop is heading is never a guess.
///
/// Nothing is accepted here. The rail reports every payload as refused, so the
/// drag passes straight through to the playlist rows the spring just revealed.
class PlaylistDragSpring extends StatefulWidget {
  const PlaylistDragSpring({
    required this.onSpring,
    required this.builder,
    super.key,
  });

  /// How long a drag has to rest on the rail before the tab changes.
  ///
  /// Long enough that crossing the rail on the way somewhere else does not
  /// yank the page out from under the drag; short enough that a deliberate
  /// hover does not feel stuck.
  static const Duration dwell = Duration(milliseconds: 600);

  /// Called once per hover, when the dwell elapses.
  ///
  /// It fires even when the Playlists tab is already the selected one: that
  /// branch can be showing Favorites or a smart mix, neither of which takes a
  /// drop, and springing is what puts the drag back on the playlist list.
  final VoidCallback onSpring;

  /// Builds the navigation region. [hovering] is true while a track drag is
  /// over it, so the destination it would spring to can say so.
  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  State<PlaylistDragSpring> createState() => _PlaylistDragSpringState();
}

class _PlaylistDragSpringState extends State<PlaylistDragSpring> {
  Timer? _timer;
  bool _hovering = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onEnter() {
    if (_hovering) return;
    setState(() => _hovering = true);
    _timer?.cancel();
    _timer = Timer(PlaylistDragSpring.dwell, () {
      // The drag can end, or the widget go away, inside the dwell.
      if (!mounted || !_hovering) return;
      widget.onSpring();
    });
  }

  void _onLeave() {
    _timer?.cancel();
    _timer = null;
    if (!_hovering) return;
    setState(() => _hovering = false);
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<PlaylistDragPayload>(
      // Never takes the drop: the rail is a route to the playlists, not a
      // destination. Reporting the payload as rejected still enters and leaves
      // this target, which is all the dwell needs.
      onWillAcceptWithDetails: (_) {
        _onEnter();
        return false;
      },
      onLeave: (_) => _onLeave(),
      builder: (
        BuildContext context,
        List<PlaylistDragPayload?> candidate,
        List<dynamic> rejected,
      ) {
        return widget.builder(context, _hovering);
      },
    );
  }
}
