import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../shared/layout/pane_layout.dart';
import 'queue_sheet.dart';

/// Width of the persistent desktop queue column.
///
/// The same number the Now Playing pane uses: the queue is a list of song rows
/// wherever it is drawn, and rows have a width that reads well. A flex share
/// would only pull each title away from its handle as the window grows.
const double queueSidePanelWidth = 340;

/// What the desktop navigation rail and the two hairline dividers take out of
/// the window before either column gets a pixel.
///
/// Measured rather than derived: a labelled [NavigationRail] is as wide as its
/// longest destination, which is a text measurement and not a constant anyone
/// can look up. A shell test pins the budget this number is standing in for,
/// so a wider rail is caught there instead of quietly eating the page.
const double _desktopShellChromeWidth = 132;

/// The narrowest window that may host the queue beside the page.
///
/// Deliberately not "the panel fits": the panel's own column, the shell chrome
/// beside it, *and* a page still wide enough to split into list and detail
/// ([listDetailMinWidth]). A queue that costs the library its detail pane has
/// taken more than it gave, and the queue is one click away as a sheet at any
/// width.
const double queueSidePanelMinWindowWidth =
    queueSidePanelWidth + _desktopShellChromeWidth + listDetailMinWidth;

/// The playback queue as a persistent column beside the page (#416).
///
/// It is the same [QueueSheet] the phone opens as a bottom sheet and Now
/// Playing opens as a pane: the same current/up-next rows, the same reorder,
/// remove and jump actions, all going through the one [PlaybackController].
/// There is no desktop queue model: this widget is a host, not a second copy of
/// the queue, so a change made here, in the sheet, from the media session or by
/// playback itself lands in exactly one place and every surface sees it at
/// once.
///
/// Whether it exists at all is the shell's call (see `HomeShell`), from the
/// width of the window rather than from anything this widget knows.
class QueueSidePanel extends StatelessWidget {
  const QueueSidePanel({required this.onClose, super.key});

  /// Collapses the panel. The queue stays exactly as it is; only the column
  /// goes away.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: queueSidePanelWidth,
      child: Material(
        // A shade off the page beside it, so the column reads as chrome that
        // belongs to the frame rather than as more content.
        color: theme.colorScheme.surfaceContainerLow,
        // A named region rather than a loose stack of rows: a screen reader
        // lands on "Queue" and can walk out of it again, instead of having to
        // guess which list it is in. Child nodes stay explicit so the rows keep
        // their own labels and move actions.
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Queue',
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: QueueSheet(embedded: true, onClose: onClose),
          ),
        ),
      ),
    );
  }
}

/// What the shell tells the rest of the frame about the queue column: whether
/// this window is wide enough to host one, whether it is open, and how to flip
/// that.
///
/// The visibility lives in the shell because the *layout* owns it, the same
/// place the rail and the bottom bar are chosen. Anything that wants to offer
/// the toggle (the mini-player's queue button) reads it from here instead of
/// re-deriving the breakpoint, so there is one answer to "is there a queue
/// column right now" rather than two that can disagree.
///
/// Queue *state* is not in here, and must not be: that stays in the shared
/// [PlaybackController] every surface already reads.
class QueueSidePanelScope extends InheritedWidget {
  const QueueSidePanelScope({
    required this.available,
    required this.visible,
    required this.onToggle,
    required super.child,
    super.key,
  });

  /// Whether the frame is wide enough to draw the panel at all. False on a
  /// phone, on Android at any width, and on a desktop window narrower than
  /// [queueSidePanelMinWindowWidth].
  final bool available;

  /// Whether the panel is currently open. Always false while [available] is.
  final bool visible;

  /// Opens the panel, or closes it again.
  final VoidCallback onToggle;

  /// The nearest scope, or null when nothing above hosts a queue column: a
  /// phone, or any surface outside the shell (the full Now Playing route,
  /// which draws its own pane).
  static QueueSidePanelScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<QueueSidePanelScope>();
  }

  @override
  bool updateShouldNotify(QueueSidePanelScope oldWidget) {
    return available != oldWidget.available ||
        visible != oldWidget.visible ||
        onToggle != oldWidget.onToggle;
  }
}
