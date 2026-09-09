import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../app/dimens.dart';

/// The modifier the move chord is spelled with on [platform].
///
/// Both modifiers stay registered everywhere — an unused activator costs
/// nothing — but the hint has to name the one that actually works here. On
/// macOS Ctrl+Arrow belongs to Mission Control and never reaches the app, so a
/// hint saying Ctrl there would point people at a chord the OS eats.
String reorderModifierLabel(TargetPlatform platform) =>
    platform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl';

/// The row being dragged: lifted off the list on a shadow so it reads as picked
/// up rather than merely highlighted. Desktop pointers have no haptics and no
/// long-press wind-up, so this elevation is the only feedback that the drag
/// actually took.
///
/// Pass it as a reorderable list's `proxyDecorator` so every list in the app
/// lifts a row the same way.
Widget liftedReorderProxy(
  Widget child,
  int index,
  Animation<double> animation,
) {
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

/// Asks for the focused row to move [delta] positions (-1 up, +1 down).
class _MoveItemIntent extends Intent {
  const _MoveItemIntent(this.delta);

  final int delta;
}

/// The reorder affordance on a reorderable row: a pointer drag target that is
/// also a real focusable control.
///
/// Dragging is the fast path. The rest is what a drag alone cannot serve:
/// **Ctrl + ↑ / ↓** (Cmd on macOS) moves the focused row without a pointer, and
/// the same two moves are offered as custom semantics actions so a screen
/// reader can reorder the list too. Hosts run all three routes through one
/// callback, so there is one reorder path rather than a keyboard copy of one.
///
/// The chord takes a modifier on purpose: a bare arrow inside a scrolling list
/// belongs to focus traversal and scrolling, and stealing it would trade one
/// accessible behaviour for another.
///
/// Shared by the queue's Up Next list and the playlist editor (#388, #389) so
/// the two lists cannot drift into two different reorder gestures. Pair it with
/// a [ReorderFocusWalk] on the host, which is what keeps a held chord walking
/// one row rather than whatever slid under the focus.
class ReorderHandle extends StatelessWidget {
  const ReorderHandle({
    required this.index,
    required this.count,
    required this.focusNode,
    required this.onMoveBy,
    super.key,
  });

  /// This row's position in the list, as the reorderable list numbers them.
  final int index;

  /// How many rows the list has, so the ends offer only the move that exists.
  final int count;

  final FocusNode focusNode;

  /// Moves this row by the given delta (-1 up, +1 down).
  final ValueChanged<int> onMoveBy;

  /// Shortcuts sit *above* the focus node, not inside it: a key event travels
  /// up from the focused node, so a [Shortcuts] below it would never see one.
  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp, control: true):
        _MoveItemIntent(-1),
    SingleActivator(LogicalKeyboardKey.arrowDown, control: true):
        _MoveItemIntent(1),
    SingleActivator(LogicalKeyboardKey.arrowUp, meta: true):
        _MoveItemIntent(-1),
    SingleActivator(LogicalKeyboardKey.arrowDown, meta: true):
        _MoveItemIntent(1),
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
          _MoveItemIntent: CallbackAction<_MoveItemIntent>(
            onInvoke: (_MoveItemIntent intent) {
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
                          '${reorderModifierLabel(theme.platform)} + ↑ / ↓)',
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
