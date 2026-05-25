import 'package:flutter/material.dart';
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
}
