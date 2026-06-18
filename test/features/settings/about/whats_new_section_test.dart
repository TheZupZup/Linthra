import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/features/settings/about/whats_new_section.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: WhatsNewSection())),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('WhatsNewSection', () {
    testWidgets('shows the section title and current app version',
        (tester) async {
      await _pump(tester);

      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Linthra ${AppInfo.version}'), findsOneWidget);
    });

    testWidgets('shows the closed-testing release notes', (tester) async {
      await _pump(tester);

      expect(
        find.text('Added support and bug report links for testers.'),
        findsOneWidget,
      );
      expect(
        find.text('Added a copyable app-info block for easier bug reports.'),
        findsOneWidget,
      );
      expect(
        find.text('Improved About and project information.'),
        findsOneWidget,
      );
      expect(
        find.text('Continued Google Play closed testing preparation.'),
        findsOneWidget,
      );
      expect(find.text('Stability and polish improvements.'), findsOneWidget);
    });
  });
}
