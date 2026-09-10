import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../player/mini_player.dart';
import 'playlist_drag_spring.dart';

/// The persistent app frame: hosts the active tab and the app's primary
/// navigation. Tab state is owned by go_router's [StatefulNavigationShell], so
/// each tab keeps its own stack and scroll position across switches.
class HomeShell extends StatelessWidget {
  const HomeShell({
    required this.navigationShell,
    required this.rootNavigatorKey,
    required this.branchNavigatorKeys,
    super.key,
  }) : assert(branchNavigatorKeys.length == _destinations.length);

  final StatefulNavigationShell navigationShell;
  final GlobalKey<NavigatorState> rootNavigatorKey;
  final List<GlobalKey<NavigatorState>> branchNavigatorKeys;

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

  void _onDestinationSelected(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  Future<bool> _handleSystemBack() async {
    if (rootNavigatorKey.currentState?.canPop() ?? false) return false;

    final int currentIndex = navigationShell.currentIndex;
    final NavigatorState? activeBranch =
        branchNavigatorKeys[currentIndex].currentState;
    if (activeBranch?.canPop() ?? false) return false;

    if (currentIndex == 0) return false;
    navigationShell.goBranch(0);
    return true;
  }

  bool _usesDesktopNavigation(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    return Theme.of(context).platform == TargetPlatform.linux &&
        constraints.maxWidth >= desktopNavigationBreakpoint;
  }

  /// Opens the Playlists tab at its root for a drag (#389).
  ///
  /// Always the branch's initial location, unlike a tap, which restores
  /// whatever that branch had on top. Favorites and the smart mixes live
  /// inside this branch and take no drop, so restoring one of those would put
  /// the drag on a page it cannot finish on. The playlist list always can.
  void _springToPlaylists() {
    navigationShell.goBranch(playlistsBranchIndex, initialLocation: true);
  }

  /// The rail, wrapped in the drag spring so a track dragged out of the
  /// library can reach the Playlists tab (#389).
  Widget _buildNavigationRail() {
    return FocusTraversalOrder(
      order: const NumericFocusOrder(2),
      child: FocusTraversalGroup(
        child: SafeArea(
          right: false,
          child: PlaylistDragSpring(
            onSpring: _springToPlaylists,
            builder: (BuildContext context, bool dragHovering) {
              return NavigationRail(
                selectedIndex: navigationShell.currentIndex,
                onDestinationSelected: _onDestinationSelected,
                labelType: NavigationRailLabelType.all,
                groupAlignment: -1,
                destinations: <NavigationRailDestination>[
                  for (int i = 0; i < _destinations.length; i++)
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
    final NavigationDestination destination = _destinations[index];
    final bool marked = dragHovering && index == playlistsBranchIndex;
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
  /// A Linux window narrower than [desktopNavigationBreakpoint] shows this
  /// instead of the rail, and a mouse is still a mouse there: the drag starts
  /// whatever the width, so without a spring here it would pick a row up and
  /// have nowhere in the app to put it. On a phone no drag ever reaches this,
  /// because the drag source is desktop-only.
  Widget _buildNavigationBar() {
    return PlaylistDragSpring(
      onSpring: _springToPlaylists,
      builder: (BuildContext context, bool dragHovering) {
        return NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: _onDestinationSelected,
          destinations: <Widget>[
            for (int i = 0; i < _destinations.length; i++)
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
    final NavigationDestination destination = _destinations[index];
    if (!(dragHovering && index == playlistsBranchIndex)) return destination;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Icon marker = Icon(Icons.playlist_add, color: accent);
    return NavigationDestination(
      icon: marker,
      selectedIcon: marker,
      label: destination.label,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BackButtonListener(
      onBackButtonPressed: _handleSystemBack,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool desktop = _usesDesktopNavigation(context, constraints);

          // Keep StatefulNavigationShell at the same element position across
          // the 900 px breakpoint. Only the two chrome slots before it change
          // between real desktop widgets and zero-sized placeholders, so an
          // inactive branch's Navigator stack and scroll state survive resize.
          //
          // The mini-player sits below the whole frame rather than inside the
          // content column, so on a desktop window the now-playing bar runs the
          // full width under the rail — the shape every desktop music player
          // has. On phones there is no rail, so nothing about it moves.
          return Scaffold(
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
                              child: navigationShell,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Last in the reading order: the bar spans everything above
                  // it, so a keyboard user reaches it after both the page and
                  // the destinations, not between them.
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(3),
                    child: FocusTraversalGroup(
                      child: const MiniPlayer(),
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: desktop ? null : _buildNavigationBar(),
          );
        },
      ),
    );
  }
}
