import 'package:flutter/material.dart';

import '../../app/dimens.dart';
import 'adaptive_layout.dart';

/// Width of a fixed side pane that holds one thing's header: a cover, a title
/// block and its two transport buttons.
///
/// Album and artist detail both draw exactly this pane, which is why the number
/// lives here rather than once per screen.
const double sidePaneWidth = 320;

/// Width given to a detail pane beside a list or grid.
///
/// Enough for a cover, a title block and a column of track rows without the
/// titles truncating; narrow enough that the grid beside it keeps several
/// columns. It is a fixed width rather than a flex share because both halves
/// have a natural size: the grid grows by whole cards, and the detail is a
/// column of rows that reads badly stretched.
const double detailPaneWidth = 460;

/// The narrowest a surface may be and still split into list and detail.
///
/// The pane's own width plus the room a grid needs to stay a grid. Below this a
/// split would leave two cramped columns where one comfortable one fits, so the
/// detail goes back to being a page of its own.
const double listDetailMinWidth = detailPaneWidth + mediumWindowWidth;

/// A list (or grid) that gains a detail pane once its box is wide enough to
/// hold one.
///
/// This is the composition seam for Linthra's desktop layouts: inside the shell
/// the navigation rail is already a pane, so a screen that splits itself here
/// makes the window read as navigation · content · detail without any screen
/// having to know it is one of three.
///
/// The split is decided from the box this widget is given, not from the window
/// or the platform, so it holds wherever the screen is hosted — inside the
/// desktop shell, on a tablet, in a test that pumps it at a fixed size. The
/// same rule as everywhere else in `shared/layout`.
///
/// It deliberately owns no selection state. The host keeps that, which is what
/// makes the two modes one screen rather than two: [listBuilder] is told which
/// mode it is in so a tap opens the right one, and what the user picked in
/// either survives crossing the threshold.
///
/// That last part is the host's job, and it is easy to get wrong: dropping the
/// pane unmounts the detail outright, so any state the detail holds itself,
/// including a track selection in progress, goes with it on a resize the user
/// never thought of as leaving the screen. State that has to outlive the pane
/// belongs to the host and is passed down (see `LibraryScreen`).
class ListDetailPanes extends StatelessWidget {
  const ListDetailPanes({
    required this.listBuilder,
    required this.detailBuilder,
    required this.placeholderBuilder,
    this.paneWidth = detailPaneWidth,
    this.minWidthForPane = listDetailMinWidth,
    super.key,
  });

  /// The list or grid. Told whether a detail pane is on screen beside it, so it
  /// can select into the pane instead of pushing a route.
  final Widget Function(BuildContext context, bool paneVisible) listBuilder;

  /// The detail for the current selection, or null when there is none. Only
  /// called while the pane is visible.
  final Widget? Function(BuildContext context) detailBuilder;

  /// What the pane shows with nothing selected. A pane that blinks in and out
  /// as the selection changes would make the grid beside it reflow on every
  /// tap, so the pane holds its width and shows this instead.
  final WidgetBuilder placeholderBuilder;

  final double paneWidth;
  final double minWidthForPane;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool paneVisible = constraints.maxWidth >= minWidthForPane;
        final Widget list = listBuilder(context, paneVisible);
        if (!paneVisible) return list;

        return SplitPanes(
          fixed: detailBuilder(context) ?? placeholderBuilder(context),
          fixedWidth: paneWidth,
          flexible: list,
          fixedFirst: false,
          // A grid is happy at any width — it answers extra room with more
          // cards — so this one is not capped the way a column of rows is.
          maxWidth: double.infinity,
        );
      },
    );
  }
}

/// Two panes side by side with a hairline between them: one at a fixed width,
/// the other taking what is left.
///
/// The shape every desktop composition in Linthra ends up wanting — a header
/// pane beside a scrolling list, a grid beside a detail — written once so the
/// divider, the cap and the stretch behaviour cannot drift apart between them.
///
/// Content is capped at [maxWidth] and centred: past that, a two-pane layout
/// stops using extra width to pull its halves apart. Callers whose flexible
/// half genuinely wants every pixel (a grid) pass `double.infinity`.
class SplitPanes extends StatelessWidget {
  const SplitPanes({
    required this.fixed,
    required this.fixedWidth,
    required this.flexible,
    this.fixedFirst = true,
    this.maxWidth = maxPaneLayoutWidth,
    super.key,
  });

  /// The pane with a natural width — a cover and its actions, one album's page.
  final Widget fixed;
  final double fixedWidth;

  /// The pane that takes the rest, usually a list or a grid.
  final Widget flexible;

  /// Whether [fixed] sits before [flexible] in the reading order.
  final bool fixedFirst;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final Widget fixedPane = SizedBox(width: fixedWidth, child: fixed);
    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (fixedFirst) fixedPane else Expanded(child: flexible),
        const VerticalDivider(width: 1),
        if (fixedFirst) Expanded(child: flexible) else fixedPane,
      ],
    );
    if (!maxWidth.isFinite) return row;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: row,
      ),
    );
  }
}

/// The calm "nothing picked yet" state for a [ListDetailPanes] pane.
class DetailPanePlaceholder extends StatelessWidget {
  const DetailPanePlaceholder({
    required this.icon,
    required this.message,
    super.key,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: muted),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
