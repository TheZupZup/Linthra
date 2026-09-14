import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/focus/focus_handoff.dart';
import '../player/mini_player.dart';
import '../player/widgets/queue_side_panel.dart';
import 'playlist_drag_spring.dart';

/// The persistent app frame: hosts the active tab and the app's primary
/// navigation. Tab state is owned by go_router's [StatefulNavigationShell], so
/// each tab keeps its own stack and scroll position across switches.
class HomeShell extends StatefulWidget {
  const HomeShell({
    required this.navigationShell,
    required this.rootNavigatorKey,
    required this.branchNavigatorKeys,
    super.key,
  }) : assert(branchNavigatorKeys.length == _destinations.length);

  final StatefulNavigationShell navigationShell;
  final GlobalKey<NavigatorState> rootNavigatorKey;
  final List<GlobalKey<NavigatorState>> branchNavigatorKeys;

  @override
  State<HomeShell> createState() => _HomeShellState();

  /// Wide Linux windows get a persistent desktop navigation region instead of
  /// the phone-oriented bottom navigation bar. Keeping the breakpoint here
  /// gives the shell one reusable presentation seam instead of scattering
  /// platform checks through feature screens.
  static const double desktopNavigationBreakpoint = 900;

  /// Which branch the Playlists tab is, so the drag spring and the destination
  /// list can never disagree about it. A const constructor cannot assert
  /// against a destination's label, so a test pins the two together instead;
  /// [destinationLabels] is what it reads.
  static const int playlistsBranchIndex = 2;

  /// The destination labels, in branch order, for tests that need to know
  /// which index is which without reaching into private state.
  static List<String> get destinationLabels => <String>[
        for (final NavigationDestination destination in _destinations)
          destination.label,
      ];

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.library_music_outlined),
      selectedIcon: Icon(Icons.library_music),
      label: 'Library',
    ),
    // Folders sits beside Library rather than inside it: both are ways of
    // browsing the same collection, and as its own branch the folder trail
    // survives a trip to another tab.
    NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder),
      label: 'Folders',
    ),
    NavigationDestination(
      icon: Icon(Icons.queue_music_outlined),
      selectedIcon: Icon(Icons.queue_music),
      label: 'Playlists',
    ),
    NavigationDestination(
      icon: Icon(Icons.download_outlined),
      selectedIcon: Icon(Icons.download),
      label: 'Downloads',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];
}

/// The frame's own state: which tab is showing is go_router's, but whether the
/// desktop queue column is open is the frame's, and nothing below it needs to
/// know.
class _HomeShellState extends State<HomeShell> {
  /// Whether the queue column is open, when the window is wide enough to draw
  /// one.
  ///
  /// Remembered even while the window is too narrow for the column, so dragging
  /// a window down to a phone width and back finds the queue where it was left
  /// rather than closed, the same promise Now Playing's pane makes. Starts
  /// closed: the column costs the page a whole column's width, and that is the
  /// listener's call to make, not a default to wake up to.
  bool _queuePanelOpen = false;

  /// The mini-player queue button's focus node, owned here rather than by the
  /// button (#390).
  ///
  /// Closing the column disposes every control in it, the ✕ the user just
  /// pressed included, so without somewhere to put the keyboard it unwinds to
  /// the page and the next Tab restarts from the top. Handing it back to the
  /// button that reopens the column keeps the user exactly where they were, and
  /// the node has to outlive the panel to be handed anything, which is why the
  /// shell holds it.
  final FocusNode _queueToggleFocus = FocusNode(
    debugLabel: 'queue panel toggle',
  );

  @override
  void dispose() {
    _queueToggleFocus.dispose();
    super.dispose();
  }

  void _toggleQueuePanel() {
    setState(() => _queuePanelOpen = !_queuePanelOpen);
  }

  void _onDestinationSelected(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  Future<bool> _handleSystemBack() async {
    if (widget.rootNavigatorKey.currentState?.canPop() ?? false) return false;

    final int currentIndex = widget.navigationShell.currentIndex;
    final NavigatorState? activeBranch =
        widget.branchNavigatorKeys[currentIndex].currentState;
    if (activeBranch?.canPop() ?? false) return false;

    if (currentIndex == 0) return false;
    widget.navigationShell.goBranch(0);
    return true;
  }

  bool _usesDesktopNavigation(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    return Theme.of(context).platform == TargetPlatform.linux &&
        constraints.maxWidth >= HomeShell.desktopNavigationBreakpoint;
  }

  /// Opens the Playlists tab at its root for a drag (#389).
  ///
  /// Always the branch's initial location, unlike a tap, which restores
  /// whatever that branch had on top. Favorites and the smart mixes live
  /// inside this branch and take no drop, so restoring one of those would put
  /// the drag on a page it cannot finish on. The playlist list always can.
  void _springToPlaylists() {
    widget.navigationShell
        .goBranch(HomeShell.playlistsBranchIndex, initialLocation: true);
  }

  /// The rail, wrapped in the drag spring so a track dragged out of the
  /// library can reach the Playlists tab (#389).
  Widget _buildNavigationRail() {
    return FocusTraversalOrder(
      order: const NumericFocusOrder(3),
      child: FocusTraversalGroup(
        child: SafeArea(
          right: false,
          child: PlaylistDragSpring(
            onSpring: _springToPlaylists,
            builder: (BuildContext context, bool dragHovering) {
              return NavigationRail(
                selectedIndex: widget.navigationShell.currentIndex,
                onDestinationSelected: _onDestinationSelected,
                labelType: NavigationRailLabelType.all,
                groupAlignment: -1,
                destinations: <NavigationRailDestination>[
                  for (int i = 0; i < HomeShell._destinations.length; i++)
                    _railDestination(context, i, dragHovering: dragHovering),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// One rail destination. While a track drag is over the rail, Playlists
  /// swaps to an "add to playlist" glyph in the accent colour, so the tab the
  /// spring is about to open announces itself instead of the page simply
  /// changing under the drag.
  NavigationRailDestination _railDestination(
    BuildContext context,
    int index, {
    required bool dragHovering,
  }) {
    final NavigationDestination destination = HomeShell._destinations[index];
    final bool marked = dragHovering && index == HomeShell.playlistsBranchIndex;
    if (!marked) {
      return NavigationRailDestination(
        icon: destination.icon,
        selectedIcon: destination.selectedIcon,
        label: Text(destination.label),
      );
    }
    final Color accent = Theme.of(context).colorScheme.primary;
    final Icon marker = Icon(Icons.playlist_add, color: accent);
    return NavigationRailDestination(
      icon: marker,
      selectedIcon: marker,
      label: Text(destination.label, style: TextStyle(color: accent)),
    );
  }

  /// The bottom bar, wrapped in the same drag spring as the rail.
  ///
  /// A Linux window narrower than [HomeShell.desktopNavigationBreakpoint]
  /// shows this instead of the rail, and a mouse is still a mouse there: the
  /// drag starts
  /// whatever the width, so without a spring here it would pick a row up and
  /// have nowhere in the app to put it. On a phone no drag ever reaches this,
  /// because the drag source is desktop-only.
  Widget _buildNavigationBar() {
    return PlaylistDragSpring(
      onSpring: _springToPlaylists,
      builder: (BuildContext context, bool dragHovering) {
        return NavigationBar(
          selectedIndex: widget.navigationShell.currentIndex,
          onDestinationSelected: _onDestinationSelected,
          destinations: <Widget>[
            for (int i = 0; i < HomeShell._destinations.length; i++)
              _barDestination(context, i, dragHovering: dragHovering),
          ],
        );
      },
    );
  }

  /// One bottom-bar destination, marked the same way the rail's is while a
  /// track drag is over the bar.
  NavigationDestination _barDestination(
    BuildContext context,
    int index, {
    required bool dragHovering,
  }) {
    final NavigationDestination destination = HomeShell._destinations[index];
    final bool marked = dragHovering && index == HomeShell.playlistsBranchIndex;
    if (!marked) return destination;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Icon marker = Icon(Icons.playlist_add, color: accent);
    return NavigationDestination(
      icon: marker,
      selectedIcon: marker,
      label: destination.label,
    );
  }

  /// The queue as a third column (#416), in its own traversal group so Tab
  /// walks the panel whole (header actions, then rows) instead of weaving it
  /// into the page beside it.
  Widget _buildQueuePanel() {
    return FocusTraversalOrder(
      order: const NumericFocusOrder(2),
      child: FocusTraversalGroup(
        child: FocusHandoff(
          returnFocusTo: () => _queueToggleFocus,
          child: SafeArea(
            left: false,
            bottom: false,
            child: QueueSidePanel(onClose: _toggleQueuePanel),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BackButtonListener(
      onBackButtonPressed: _handleSystemBack,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool desktop = _usesDesktopNavigation(context, constraints);
          // The layout decides whether the panel exists at all; the queue it
          // shows is the same one every other surface reads. Gated on the
          // desktop frame as well as the width, so a wide Android tablet keeps
          // the phone layout it has always had.
          final bool queuePanelAvailable =
              desktop && constraints.maxWidth >= queueSidePanelMinWindowWidth;
          final bool queuePanelOpen = queuePanelAvailable && _queuePanelOpen;

          // Keep StatefulNavigationShell at the same element position across
          // the 900 px breakpoint. Only the two chrome slots before it change
          // between real desktop widgets and zero-sized placeholders, so an
          // inactive branch's Navigator stack and scroll state survive resize.
          // The queue column is the same trick on the other side: it holds two
          // slots after the shell whether or not it is drawn.
          //
          // The mini-player sits below the whole frame rather than inside the
          // content column, so on a desktop window the now-playing bar runs the
          // full width under the rail — the shape every desktop music player
          // has. On phones there is no rail, so nothing about it moves.
          return QueueSidePanelScope(
            available: queuePanelAvailable,
            visible: queuePanelOpen,
            onToggle: _toggleQueuePanel,
            toggleFocusNode: _queueToggleFocus,
            child: Scaffold(
              body: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: Row(
                        children: <Widget>[
                          if (desktop)
                            _buildNavigationRail()
                          else
                            const SizedBox.shrink(),
                          if (desktop)
                            const VerticalDivider(width: 1)
                          else
                            const SizedBox.shrink(),
                          Expanded(
                            child: FocusTraversalOrder(
                              order: const NumericFocusOrder(1),
                              child: FocusTraversalGroup(
                                child: widget.navigationShell,
                              ),
                            ),
                          ),
                          if (queuePanelOpen)
                            const VerticalDivider(width: 1)
                          else
                            const SizedBox.shrink(),
                          if (queuePanelOpen)
                            _buildQueuePanel()
                          else
                            const SizedBox.shrink(),
                        ],
                      ),
                    ),
                    // Last in the reading order: the bar spans everything above
                    // it, so a keyboard user reaches it after both the page and
                    // the destinations, not between them.
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(4),
                      child: FocusTraversalGroup(
                        child: const MiniPlayer(),
                      ),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar: desktop ? null : _buildNavigationBar(),
            ),
          );
        },
      ),
    );
  }
}
