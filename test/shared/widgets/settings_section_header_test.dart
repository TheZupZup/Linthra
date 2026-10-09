import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/settings_section_header.dart';

void main() {
  group('SettingsSectionHeader', () {
    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SettingsSectionHeader('Storage & offline'),
            ),
          ),
        );

    testWidgets('renders its title in upper case', (tester) async {
      await pump(tester);

      expect(find.text('STORAGE & OFFLINE'), findsOneWidget);
    });

    testWidgets('is a heading, read as written rather than in capitals',
        (tester) async {
      // The capitals are a look. Some screen readers spell a capitalised word
      // out letter by letter, and without the role a group title read like
      // any other line of text (#460).
      final SemanticsHandle handle = tester.ensureSemantics();
      await pump(tester);

      final Iterable<SemanticsNode> nodes = find.semantics
          .byPredicate(
            (SemanticsNode node) => node.label == 'Storage & offline',
          )
          .evaluate();
      expect(nodes, hasLength(1));
      final SemanticsData data = nodes.single.getSemanticsData();
      expect(data.flagsCollection.isHeader, isTrue);
      expect(find.bySemanticsLabel('STORAGE & OFFLINE'), findsNothing);
      handle.dispose();
    });
  });
}
