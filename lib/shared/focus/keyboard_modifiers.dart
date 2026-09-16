import 'package:flutter/services.dart';

/// Whether a shortcut modifier is being held right now.
///
/// Control, Alt and Meta are the modifiers a Linthra keyboard shortcut can be
/// built from (#391); Shift is never one on its own, so holding it alone does
/// not count here.
///
/// Widgets that answer a bare key use this to stand aside. An unmodified → is
/// "one step along" to a seek bar or a grid, but Ctrl+→ belongs to whatever
/// the user bound it to, and a widget that consumed it would leave that
/// binding dead wherever it happened to hold focus. `Shortcuts` sees the key
/// only if nothing below reports it handled.
bool shortcutModifierPressed() {
  final HardwareKeyboard keyboard = HardwareKeyboard.instance;
  return keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed;
}
