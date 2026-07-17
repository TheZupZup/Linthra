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
  tester.view.physicalSize = const Size(1000, 2200);
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
    testWidgets('explains the free-core and cosmetic-only model',
        (tester) async {
      await _pump(tester);

      expect(find.text('Support Linthra'), findsWidgets);
      expect(find.text('Linthra is free and open source'), findsOneWidget);
      expect(find.textContaining('completely optional'), findsOneWidget);
      expect(
        find.text('No ads. No tracking. No locked core features.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('supporter reward is a custom color palette'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Black & White icon themes stay free'),
        findsOneWidget,
      );

      expect(find.text('Where your support goes'), findsOneWidget);
      expect(find.text('Development and new features'), findsOneWidget);
      expect(find.text('Testing devices'), findsOneWidget);
      expect(find.text('App store and distribution costs'), findsOneWidget);
      expect(find.text('Long-term maintenance'), findsOneWidget);

      expect(
        find.textContaining('built-in icon themes stay free and unlocked'),
        findsOneWidget,
      );
      expect(find.textContaining('custom palette only'), findsOneWidget);
    });

    testWidgets('keeps the playful note secondary', (tester) async {
      await _pump(tester);

      expect(find.textContaining("I'm lonely"), findsOneWidget);
      expect(
        find.textContaining('keep Linthra alive except you'),
        findsOneWidget,
      );
      expect(find.textContaining('No pressure'), findsOneWidget);
    });

    testWidgets('renders every configured action', (tester) async {
      await _pump(tester);

      expect(find.text('GitHub Sponsors'), findsOneWidget);
      expect(find.text('View source code'), findsOneWidget);
      expect(find.text('Become a supporter'), findsOneWidget);
    });

    testWidgets('opens an external support link', (tester) async {
      final _FakeLinkLauncher launcher = await _pump(tester);

      await tester.tap(find.text('GitHub Sponsors'));
      await tester.pumpAndSettle();

      expect(launcher.opened, Uri.parse('https://example.com/sponsors'));
    });

    testWidgets('keeps the coming-soon purchase disabled', (tester) async {
      final _FakeLinkLauncher launcher = await _pump(tester);

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

    testWidgets('refuses non-web links', (tester) async {
      const List<SupportAction> nonWeb = <SupportAction>[
        SupportAction(
          id: 'bad-scheme',
          title: 'Sketchy link',
          description: 'Not a web link.',
          icon: Icons.warning_amber_outlined,
          kind: SupportActionKind.externalLink,
          url: 'tel:+15551234567',
        ),
      ];
      final _FakeLinkLauncher launcher = await _pump(tester, actions: nonWeb);

      await tester.tap(find.text('Sketchy link'));
      await tester.pumpAndSettle();

      expect(launcher.opened, isNull);
      expect(find.text("Couldn't open the link."), findsOneWidget);
    });

    testWidgets('links-disabled build remains informational', (tester) async {
      await _pump(tester, actions: const <SupportAction>[]);

      expect(find.text('Linthra is free and open source'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(find.textContaining("I'm lonely"), findsNothing);
    });
  });
}
