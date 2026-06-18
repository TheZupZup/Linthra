import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/about/tester_checklist_section.dart';

Future<void> _pump(WidgetTester tester) async {
  // A tall surface so the whole card lays out and every item is rendered.
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: TesterChecklistSection())),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TesterChecklistSection', () {
    testWidgets('shows the checklist title', (tester) async {
      await _pump(tester);

      expect(find.text('Tester checklist'), findsOneWidget);
    });

    testWidgets('renders every checklist item', (tester) async {
      await _pump(tester);

      // There is at least one thing to try, and the items are kept short.
      expect(TesterChecklistSection.items, isNotEmpty);
      for (final String item in TesterChecklistSection.items) {
        expect(find.text(item), findsOneWidget);
      }
    });
  });
}
