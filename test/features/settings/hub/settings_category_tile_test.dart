import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/hub/settings_category_tile.dart';

void main() {
  group('SettingsCategoryTile', () {
    testWidgets('shows the icon, title, and subtitle', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsCategoryTile(
              icon: Icons.hub_outlined,
              title: 'Connections',
              subtitle: 'Jellyfin, Plex, local files',
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Connections'), findsOneWidget);
      expect(find.text('Jellyfin, Plex, local files'), findsOneWidget);
      expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
      // A chevron signals the row drills into its own page.
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsCategoryTile(
              icon: Icons.info_outline,
              title: 'About',
              subtitle: 'Version and links',
              onTap: () => taps++,
            ),
          ),
        ),
      );

      await tester.tap(find.text('About'));
      expect(taps, 1);
    });
  });
}
