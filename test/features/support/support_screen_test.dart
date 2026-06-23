import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/features/support/support_action.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/support_screen.dart';

class _FakeLinkLauncher implements ExternalLinkLauncher {
  _FakeLinkLauncher({this.result = true});

  final bool result;
  Uri? opened;

  @override
  Future<bool> open(Uri url) async {
    opened = url;
    return result;
  }
}

/// A fixed action list — two external links and a disabled placeholder — so the
/// screen test is independent of the build flavor and exercises both kinds.
const List<SupportAction> _actions = <SupportAction>[
  SupportAction(
    id: 'github-sponsors',
    title: 'GitHub Sponsors',
    description: 'Sponsor on GitHub.',
    icon: Icons.favorite_outline,
    kind: SupportActionKind.externalLink,
    url: 'https://example.com/sponsors',
  ),
  SupportAction(
    id: 'source-code',
    title: 'View source code',
    description: 'Read the code.',
    icon: Icons.code_outlined,
    kind: SupportActionKind.externalLink,
    url: 'https://example.com/repo',
  ),
  SupportAction(
    id: 'play-supporter',
    title: 'Become a supporter',
    description: 'Coming soon to the Play Store edition.',
    icon: Icons.card_giftcard_outlined,
    kind: SupportActionKind.comingSoon,
  ),
];

Future<_FakeLinkLauncher> _pump(
  WidgetTester tester, {
  bool launchResult = true,
  List<SupportAction> actions = _actions,
}) async {
  final _FakeLinkLauncher launcher = _FakeLinkLauncher(result: launchResult);
  // A tall surface so every card and row is laid out and hittable — a ListView
  // only builds the rows it can show.
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        externalLinkLauncherProvider.overrideWithValue(launcher),
        supportActionsProvider.overrideWithValue(actions),
      ],
      child: const MaterialApp(home: SupportScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return launcher;
}

void main() {
  group('SupportScreen', () {
    testWidgets('explains that Linthra is free, optional, and stays free',
        (tester) async {
      await _pump(tester);

      expect(find.text('Support Linthra'), findsWidgets);
      expect(find.text('Linthra is free and open source'), findsOneWidget);
      expect(find.textContaining('completely optional'), findsOneWidget);
      // The crisp, scannable trio stays visible.
      expect(
        find.text('No ads. No tracking. No locked core features.'),
        findsOneWidget,
      );

      // Where support goes — the four funded areas.
      expect(find.text('Where your support goes'), findsOneWidget);
      expect(find.text('Development and new features'), findsOneWidget);
      expect(find.text('Testing devices'), findsOneWidget);
      expect(find.text('App store and distribution costs'), findsOneWidget);
      expect(find.text('Long-term maintenance'), findsOneWidget);

      // The core-stays-free reassurance — support changes nothing.
      expect(
          find.textContaining('All core features stay free'), findsOneWidget);
      expect(find.textContaining('unlocks nothing'), findsOneWidget);
    });

    testWidgets(
        'includes a secondary, playful "lonely maintainer" note with '
        '"No pressure" kept visible', (tester) async {
      await _pump(tester);

      expect(find.textContaining("I'm lonely"), findsOneWidget);
      expect(
        find.textContaining('keep Linthra alive except you'),
        findsOneWidget,
      );
      // The anti-guilt-trip reassurance is present and visible.
      expect(find.textContaining('No pressure'), findsOneWidget);
      expect(find.textContaining('build something cool'), findsOneWidget);
    });

    testWidgets('renders a row per action from the provider', (tester) async {
      await _pump(tester);

      expect(find.text('GitHub Sponsors'), findsOneWidget);
      expect(find.text('View source code'), findsOneWidget);
      expect(find.text('Become a supporter'), findsOneWidget);
    });

    testWidgets('tapping an external-link action opens its URL',
        (tester) async {
      final _FakeLinkLauncher launcher = await _pump(tester);

      await tester.tap(find.text('GitHub Sponsors'));
      await tester.pumpAndSettle();

      expect(launcher.opened, Uri.parse('https://example.com/sponsors'));
    });

    testWidgets('the coming-soon placeholder is disabled and opens nothing',
        (tester) async {
      final _FakeLinkLauncher launcher = await _pump(tester);

      expect(find.text('Coming soon'), findsOneWidget);
      final ListTile tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Become a supporter'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.enabled, isFalse);
      expect(tile.onTap, isNull);
      expect(launcher.opened, isNull);
    });

    testWidgets('shows a snackbar when a link cannot be opened',
        (tester) async {
      await _pump(tester, launchResult: false);

      await tester.tap(find.text('View source code'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the link."), findsOneWidget);
    });
  });
}
