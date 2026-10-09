import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/hub/connections_settings_screen.dart';

void main() {
  testWidgets('the Music and Audiobooks group titles are headings',
      (WidgetTester tester) async {
    // A screen reader jumps heading to heading; without the role the two
    // groups only showed as coloured text (#460).
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ConnectionsSettingsScreen()),
      ),
    );
    await tester.pump();

    for (final String title in <String>['Music', 'Audiobooks']) {
      final Iterable<SemanticsNode> nodes = find.semantics
          .byPredicate((SemanticsNode node) => node.label == title)
          .evaluate();
      expect(nodes, hasLength(1), reason: title);
      expect(nodes.single.flagsCollection.isHeader, isTrue, reason: title);
    }
    handle.dispose();
  });
}
