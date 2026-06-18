import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/app_info.dart';
import 'package:linthra/features/settings/about/whats_new_section.dart';

Future<void> _pump(WidgetTester tester) async {
  // A tall surface so the whole card lays out and every bullet is rendered.
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: WhatsNewSection())),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('WhatsNewSection', () {
    testWidgets('shows the title and the running app version', (tester) async {
      await _pump(tester);

      expect(find.text("What's new"), findsOneWidget);
      // The current version comes from AppInfo (the in-app source of truth),
      // shown beside the title so the highlights are tied to this build.
      expect(find.text('Version ${AppInfo.version}'), findsOneWidget);
    });

    testWidgets('renders every release-note bullet', (tester) async {
      await _pump(tester);

      // There is at least one highlight to show, and they are kept short.
      expect(WhatsNewSection.releaseNotes, isNotEmpty);
      for (final String note in WhatsNewSection.releaseNotes) {
        expect(find.text(note), findsOneWidget);
      }
    });
  });
}
