import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens a menu on right-click, and on the keyboard's menu key.
///
/// The desktop half of the per-item actions Linthra already has (#386). Every
/// menu here is the *same* menu the row's 3-dot button opens — same entries,
/// same state, same commands — so a right-click can never offer something a tap
/// cannot, or run it differently.
///
/// Keyboard parity comes with it rather than as an afterthought: with the row
/// focused, the context-menu key (or Shift+F10, which keyboards without one
/// send) opens the same menu, centred on the row. Key events bubble from the
/// focused descendant, so a row only has to be focusable — which every tappable
/// row already is.
///
/// Touch is untouched: a long-press is still whatever the child made it, and
/// nothing here responds to a primary tap.
class ContextMenuRegion<T> extends StatelessWidget {
  const ContextMenuRegion({
    required this.itemBuilder,
    required this.onSelected,
    required this.child,
    this.enabled = true,
    super.key,
  });

  /// Built fresh every time the menu opens, so it reflects the state as it is
  /// at that moment — downloaded, favorited, what the queue holds.
  final List<PopupMenuEntry<T>> Function(BuildContext context) itemBuilder;

  final void Function(T value) onSelected;

  final Widget child;

  /// Whether the menu can be opened at all. A row in selection mode, say, is
  /// acting on a set rather than on itself.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Focus(
      // Not focusable itself: this only listens to what the row inside it does
      // with the keyboard. Adding a stop of its own would put an empty node in
      // everyone's Tab order.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool isMenuKey =
            event.logicalKey == LogicalKeyboardKey.contextMenu ||
                (event.logicalKey == LogicalKeyboardKey.f10 &&
                    HardwareKeyboard.instance.isShiftPressed);
        if (!isMenuKey) return KeyEventResult.ignored;
        _openAt(context, _centreOf(context));
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        // Secondary buttons only: a primary tap is the child's, and the child
        // is hit first either way.
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (TapUpDetails details) =>
            _openAt(context, details.globalPosition),
        child: child,
      ),
    );
  }

  /// Where a keyboard-opened menu appears: the middle of the row, which is
  /// where a pointer user would have clicked.
  Offset _centreOf(BuildContext context) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Offset.zero;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  Future<void> _openAt(BuildContext context, Offset globalPosition) async {
    final List<PopupMenuEntry<T>> items = itemBuilder(context);
    if (items.isEmpty) return;
    final RenderObject? overlay =
        Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;

    // showMenu reads its position in the *overlay's* coordinate space, not in
    // screen coordinates — and the nearest overlay is rarely at the screen
    // origin. Inside the desktop shell it belongs to the branch navigator,
    // which starts after the navigation rail, so handing it a raw global
    // position would slide every menu across by the rail's width and clamp it
    // against bounds measured from the wrong corner.
    final Offset anchor = overlay.globalToLocal(globalPosition);

    final T? value = await showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(anchor, anchor),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    // The menu is a route and outlives the surface it came from: a resize that
    // crosses a pane threshold takes this region away while the popup is still
    // up. Whatever the action would reach for — the row's ref, an ancestor to
    // hang a dialog on — is gone with it, so a pick that lands after that is
    // dropped rather than dispatched into a dead tree.
    if (value != null && context.mounted) onSelected(value);
  }
}
