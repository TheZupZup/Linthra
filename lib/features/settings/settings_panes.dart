import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../shared/focus/focus_handoff.dart';
import '../../shared/focus/focus_ring.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../support/support_actions_provider.dart';
import 'hub/settings_categories.dart';
import 'settings_screen.dart';

/// Width of the category sidebar on a wide window.
const double settingsSidebarWidth = 280;

/// The frame around every Settings page (#753).
///
/// It hosts the Settings tab's own navigator, so the routes stay the one
/// source of truth for which page is open: a deep link, a row on another
/// screen and Back all work on the same stack whatever the window's width.
///
/// On an expanded window the categories sit in a sidebar and the navigator is
/// the pane beside them, the way GNOME Settings and KDE System Settings lay
/// out. A page that another one opens (Audiobooks from Connections, for example)
/// pushes inside that pane; dialogs, server sign-ins among them,
/// stay modal over the window. Narrower than that, the navigator is the whole
/// page and the hub's own list of categories is its first page, exactly as on
/// a phone.
///
/// The navigator keeps its place in the tree across the breakpoint, so
/// resizing never rebuilds it: the open page, its scroll position and whatever
/// is typed into it all survive, like the Library's panes.
class SettingsPanes extends ConsumerWidget {
  const SettingsPanes({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  /// The key of the navigator in [child], so the keyboard has somewhere to go
  /// when the sidebar is dropped from under it.
  final GlobalKey<NavigatorState> navigatorKey;

  /// The Settings pages' navigator.
  final Widget child;

  /// Where every settings page in the stack is, bottom page first.
  static List<String> _stack(BuildContext context) {
    final List<String> locations = <String>[];
    void walk(List<RouteMatchBase> matches) {
      for (final RouteMatchBase match in matches) {
        if (match is ShellRouteMatch) {
          walk(match.matches);
        } else {
          locations.add(match.matchedLocation);
        }
      }
    }

    final GoRouter? router = GoRouter.maybeOf(context);
    if (router != null) {
      walk(router.routerDelegate.currentConfiguration.matches);
    }
    return locations;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<SettingsCategory> categories = settingsCategories(
      context,
      showSupport: ref.watch(supportLinksEnabledProvider),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool split = windowSizeClassFor(constraints.maxWidth)
            .isAtLeast(WindowSizeClass.expanded);
        return SettingsPanesScope(
          split: split,
          categoryRoutes: <String>{
            for (final SettingsCategory category in categories)
              if (category.opensPage) category.route,
          },
          // The navigator holds the last slot in both layouts, and the two
          // before it only switch between real chrome and nothing, so the
          // element tree under it is never torn down by a resize.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (split)
                FocusHandoff(
                  // The sidebar holding the keyboard goes with the width. The
                  // page is what is left, and is where the user was working.
                  returnFocusTo: () => navigatorKey.currentState?.focusNode,
                  child: SizedBox(
                    width: settingsSidebarWidth,
                    child: FocusTraversalGroup(
                      child: SettingsSidebar(
                        categories: categories,
                        selected: selectedSettingsCategory(
                          categories,
                          _stack(context),
                        ),
                      ),
                    ),
                  ),
                )
              else
                const SizedBox.shrink(),
              if (split)
                const VerticalDivider(width: 1)
              else
                const SizedBox.shrink(),
              Expanded(child: FocusTraversalGroup(child: child)),
            ],
          ),
        );
      },
    );
  }
}

/// Tells the Settings pages whether they are drawn beside the sidebar.
class SettingsPanesScope extends InheritedWidget {
  const SettingsPanesScope({
    required this.split,
    required this.categoryRoutes,
    required super.child,
    super.key,
  });

  /// Whether the categories are in a sidebar beside the pages.
  final bool split;

  /// The routes of the category pages the sidebar opens.
  final Set<String> categoryRoutes;

  /// Whether the categories are on screen beside the page at [context].
  static bool isSplit(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsPanesScope>()?.split ??
      false;

  /// Whether the page at [context] is a category's own page shown beside the
  /// sidebar. Back from there would only blank the pane, and the sidebar is
  /// already the way to every other category, so such a page offers no Back.
  /// A page opened from inside one (Audiobooks from Connections) still does.
  static bool isSidebarPage(BuildContext context) {
    final SettingsPanesScope? scope =
        context.dependOnInheritedWidgetOfExactType<SettingsPanesScope>();
    if (scope == null || !scope.split) return false;
    return scope.categoryRoutes
        .contains(GoRouterState.of(context).matchedLocation);
  }

  @override
  bool updateShouldNotify(SettingsPanesScope oldWidget) =>
      split != oldWidget.split ||
      !_sameRoutes(categoryRoutes, oldWidget.categoryRoutes);

  static bool _sameRoutes(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// The categories as a sidebar, with the open one selected.
class SettingsSidebar extends StatefulWidget {
  const SettingsSidebar({
    required this.categories,
    required this.selected,
    super.key,
  });

  final List<SettingsCategory> categories;
  final SettingsCategory? selected;

  @override
  State<SettingsSidebar> createState() => _SettingsSidebarState();
}

class _SettingsSidebarState extends State<SettingsSidebar> {
  /// One node per row, by route, so a row can be handed the keyboard back.
  final Map<String, FocusNode> _rowFocus = <String, FocusNode>{};

  /// Puts the keyboard back on a row once the page it opened has taken it.
  /// Null when nothing is waiting.
  VoidCallback? _reclaim;

  FocusNode _focusFor(SettingsCategory category) => _rowFocus.putIfAbsent(
        category.route,
        () => FocusNode(debugLabel: 'settings sidebar ${category.title}'),
      );

  /// Keeps the keyboard on [row] while the page it opens arrives.
  ///
  /// A page takes the keyboard as its route comes in, which is right on a
  /// phone, where the page is all there is. Beside the sidebar it would drop
  /// the user out of the list they are walking, so the first focus change
  /// after the switch is answered by handing the row its focus back. Two
  /// frames later the offer lapses, so a click into the page afterwards is
  /// never undone.
  void _holdFocusOn(FocusNode row) {
    _releaseReclaim();
    void reclaim() {
      _releaseReclaim();
      if (mounted && row.context != null && !row.hasPrimaryFocus) {
        row.requestFocus();
      }
    }

    _reclaim = reclaim;
    FocusManager.instance.addListener(reclaim);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_reclaim == reclaim) _releaseReclaim();
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  void _releaseReclaim() {
    final VoidCallback? reclaim = _reclaim;
    if (reclaim == null) return;
    _reclaim = null;
    FocusManager.instance.removeListener(reclaim);
  }

  @override
  void dispose() {
    _releaseReclaim();
    for (final FocusNode node in _rowFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _open(SettingsCategory category) {
    if (!category.opensPage) {
      // The tour runs over the whole app rather than beside the sidebar.
      context.push(category.route);
      return;
    }
    final FocusNode row = _focusFor(category);
    if (row.hasPrimaryFocus) _holdFocusOn(row);
    // `go` rather than `push`: picking another category replaces the page
    // beside the sidebar instead of stacking one more page for Back to walk
    // through.
    context.go(category.route);
  }

  Widget _categoryRow(SettingsCategory category) {
    final Color primary = Theme.of(context).colorScheme.primary;
    return FocusRing(
      child: ListTile(
        focusNode: _focusFor(category),
        leading: Icon(
          category.icon,
          color: category.prominent ? primary : null,
        ),
        title: Text(category.title),
        selected: category == widget.selected,
        selectedTileColor: primary.withValues(alpha: 0.08),
        tileColor: category.prominent ? primary.withValues(alpha: 0.06) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          side: category.prominent
              ? BorderSide(color: primary.withValues(alpha: 0.5))
              : BorderSide.none,
        ),
        onTap: () => _open(category),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color primary = Theme.of(context).colorScheme.primary;
    return Material(
      child: ListView(
        key: const Key('settings_sidebar'),
        padding: const EdgeInsets.all(AppSpacing.sm),
        children: <Widget>[
          const SettingsBrandHeader(),
          for (final SettingsSection section
              in SettingsSection.values) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.xs,
              ),
              child: Text(
                section.title.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: primary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
              ),
            ),
            for (final SettingsCategory category in widget.categories)
              if (category.section == section && !category.prominent)
                _categoryRow(category),
          ],
          const SizedBox(height: AppSpacing.lg),
          for (final SettingsCategory category in widget.categories)
            if (category.prominent) _categoryRow(category),
        ],
      ),
    );
  }
}
