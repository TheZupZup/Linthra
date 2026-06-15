import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/hub/settings_detail_scaffold.dart';

void main() {
  group('SettingsDetailScaffold', () {
    testWidgets('shows the category title and stacks its children', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SettingsDetailScaffold(
            title: 'Connections',
            children: <Widget>[
              Text('CARD_ONE'),
              Text('CARD_TWO'),
            ],
          ),
        ),
      );

      expect(find.widgetWithText(AppBar, 'Connections'), findsOneWidget);
      expect(find.text('CARD_ONE'), findsOneWidget);
      expect(find.text('CARD_TWO'), findsOneWidget);
    });
  });
}
