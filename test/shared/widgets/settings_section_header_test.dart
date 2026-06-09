import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/settings_section_header.dart';

void main() {
  group('SettingsSectionHeader', () {
    testWidgets('renders its title in upper case', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsSectionHeader('Storage & offline'),
          ),
        ),
      );

      expect(find.text('STORAGE & OFFLINE'), findsOneWidget);
    });
  });
}
