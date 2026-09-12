import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/confirm_dialog.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required void Function(bool result) onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                final bool result = await showConfirmDialog(
                  context,
                  title: 'Delete 12 files?',
                  message: 'This cannot be undone.',
                  confirmLabel: 'Delete',
                );
                onResult(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the title, message and a Cancel + destructive action',
      (tester) async {
    await pumpButton(tester, onResult: (_) {});
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Delete 12 files?'), findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);
    // Never a vague "OK".
    expect(find.text('OK'), findsNothing);
  });

  testWidgets('Cancel resolves to false', (tester) async {
    bool? result;
    await pumpButton(tester, onResult: (bool r) => result = r);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('the destructive action resolves to true', (tester) async {
    bool? result;
    await pumpButton(tester, onResult: (bool r) => result = r);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('a destructive dialog opens with the safe action focused',
      (tester) async {
    await pumpButton(tester, onResult: (_) {});
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Enter has to mean "back out", never "delete": a keyboard user who opens
    // this dialog and presses it without reading must not lose their files.
    expect(
      Focus.of(tester.element(find.text('Cancel'))).hasFocus,
      isTrue,
    );
    expect(
      Focus.of(tester.element(find.text('Delete'))).hasFocus,
      isFalse,
    );
  });

  testWidgets('Tab moves from Cancel to the action, and back', (tester) async {
    await pumpButton(tester, onResult: (_) {});
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Visual order is Cancel then the action, and focus follows it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('Delete'))).hasFocus, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('Cancel'))).hasFocus, isTrue);
  });

  testWidgets('Tab never escapes the dialog while it is open', (tester) async {
    await pumpButton(tester, onResult: (_) {});
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final Set<String> visited = <String>{};
    for (int i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final BuildContext? context = FocusManager.instance.primaryFocus?.context;
      final Finder label = find.descendant(
        of: find.byWidget(context!.widget),
        matching: find.byType(Text),
      );
      if (label.evaluate().isNotEmpty) {
        visited.add((label.evaluate().first.widget as Text).data!);
      }
    }

    // Only the dialog's own two actions, however long Tab is held: a modal that
    // leaks focus to the page under it is a keyboard user typing into
    // something they cannot see.
    expect(visited, <String>{'Cancel', 'Delete'});
  });

  testWidgets('closing it puts the keyboard back where it came from',
      (tester) async {
    await pumpButton(tester, onResult: (_) {});
    Focus.of(tester.element(find.text('open'))).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Delete 12 files?'), findsOneWidget);
    expect(Focus.of(tester.element(find.text('Cancel'))).hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Back on the control that opened it, not at the top of the page.
    expect(find.text('Delete 12 files?'), findsNothing);
    expect(Focus.of(tester.element(find.text('open'))).hasFocus, isTrue);
  });

  testWidgets('a non-destructive dialog focuses the action instead',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showConfirmDialog(
                context,
                title: 'Sign in again?',
                message: 'Your session expired.',
                confirmLabel: 'Sign in',
                destructive: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(Focus.of(tester.element(find.text('Sign in'))).hasFocus, isTrue);
  });
}
