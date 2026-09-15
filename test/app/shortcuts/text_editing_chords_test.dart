import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';

/// The typing guard, checked against the real thing rather than against a
/// reading of it (#391).
///
/// [conflictsWithTextEditing] is a hand-written list of the keys a focused
/// field owns, and a list like that goes stale: a Flutter release can add a
/// chord to `DefaultTextEditingShortcuts` and turn one of Linthra's bindings
/// into a key that quietly eats an edit. So this presses every bindable chord
/// into a real `TextField` on the Linux platform and holds the guard to what
/// the field actually did with it.
///
/// One-directional on purpose. A chord the field consumes *must* be one the
/// guard stands down for; the reverse is not required, because the guard is
/// deliberately wider than the framework's map (Ctrl+C and friends produce no
/// visible change here with nothing selected, and the caret keys vary by
/// toolkit and input method).
void main() {
  const List<LogicalKeyboardKey> letters = <LogicalKeyboardKey>[
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyB,
    LogicalKeyboardKey.keyC,
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.keyE,
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyG,
    LogicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyI,
    LogicalKeyboardKey.keyJ,
    LogicalKeyboardKey.keyK,
    LogicalKeyboardKey.keyL,
    LogicalKeyboardKey.keyM,
    LogicalKeyboardKey.keyN,
    LogicalKeyboardKey.keyO,
    LogicalKeyboardKey.keyP,
    LogicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyR,
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyT,
    LogicalKeyboardKey.keyU,
    LogicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyX,
    LogicalKeyboardKey.keyY,
    LogicalKeyboardKey.keyZ,
  ];

  const List<LogicalKeyboardKey> navigation = <LogicalKeyboardKey>[
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.insert,
    LogicalKeyboardKey.space,
  ];

  final List<ShortcutBinding> candidates = <ShortcutBinding>[
    for (final LogicalKeyboardKey key in letters) ...<ShortcutBinding>[
      ShortcutBinding(key, control: true),
      ShortcutBinding(key, control: true, shift: true),
      ShortcutBinding(key, alt: true),
    ],
    for (final LogicalKeyboardKey key in navigation) ...<ShortcutBinding>[
      ShortcutBinding(key, control: true),
      ShortcutBinding(key, control: true, shift: true),
      ShortcutBinding(key, alt: true),
    ],
  ].where((ShortcutBinding b) => b.isValid).toList();

  const String initial = 'hello world';
  const int caret = 5;

  for (final ShortcutBinding binding in candidates) {
    testWidgets('${binding.label} in a Linux text field', (tester) async {
      // Set and cleared inside the body: flutter_test checks the foundation
      // debug variables as soon as the body returns, before any tearDown.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final TextEditingController controller =
          TextEditingController(text: initial);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextField(controller: controller))),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection = const TextSelection.collapsed(offset: caret);
      await tester.pump();

      Future<void> hold(LogicalKeyboardKey key, bool down) =>
          down ? tester.sendKeyDownEvent(key) : tester.sendKeyUpEvent(key);
      for (final bool down in <bool>[true, false]) {
        if (down) {
          if (binding.control) await hold(LogicalKeyboardKey.controlLeft, true);
          if (binding.shift) await hold(LogicalKeyboardKey.shiftLeft, true);
          if (binding.alt) await hold(LogicalKeyboardKey.altLeft, true);
          await tester.sendKeyEvent(binding.trigger);
        } else {
          if (binding.alt) await hold(LogicalKeyboardKey.altLeft, false);
          if (binding.shift) await hold(LogicalKeyboardKey.shiftLeft, false);
          if (binding.control) {
            await hold(LogicalKeyboardKey.controlLeft, false);
          }
        }
      }
      await tester.pumpAndSettle();

      final bool fieldTookIt = controller.text != initial ||
          controller.selection.baseOffset != caret ||
          controller.selection.extentOffset != caret;
      debugDefaultTargetPlatformOverride = null;
      if (!fieldTookIt) return;

      expect(
        conflictsWithTextEditing(binding),
        isTrue,
        reason: 'a Linux text field acts on ${binding.label}, so a shortcut '
            'bound to it has to stand down while the field has focus',
      );
    });
  }
}
