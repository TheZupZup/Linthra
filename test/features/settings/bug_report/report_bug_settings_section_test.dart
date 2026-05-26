import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/bug_report/report_bug_settings_section.dart';

void main() {
  group('ReportBugSettingsSection', () {
    testWidgets('shows the title, explanation, and entry button',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ReportBugSettingsSection()),
        ),
      );

      // The card title and the button both read "Report a bug".
      expect(find.text('Report a bug'), findsNWidgets(2));
      expect(
        find.textContaining('generated on your device'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.bug_report_outlined), findsWidgets);
    });
  });
}
