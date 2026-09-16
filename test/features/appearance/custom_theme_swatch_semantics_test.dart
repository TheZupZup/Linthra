import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/custom_theme_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_custom_theme_store.dart';
import 'package:linthra/features/appearance/appearance_settings_screen.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

/// The accent-colour swatches carried a `Semantics(label:)` *and* a `Tooltip`
/// with the same words (#90). On Android a tooltip becomes `tooltipText`
/// alongside the content description, so the swatch said its colour name
/// twice. The tooltip is still there for the mouse; the screen reader hears it
/// once.

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        customThemeStoreProvider.overrideWithValue(InMemoryCustomThemeStore()),
        supporterEntitlementProvider
            .overrideWithValue(SupporterEntitlement.unlocked),
        supportDistributionProvider
            .overrideWithValue(SupportDistribution.githubRelease),
      ],
      child: const MaterialApp(home: AppearanceSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a colour swatch names itself once, not once per carrier',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(tester);

    final Finder swatches = find.bySemanticsLabel('Orange');
    // Two: the card offers a primary and a secondary accent, and each palette
    // has the same ten colours. That is two swatches, not one said twice.
    expect(swatches, findsNWidgets(2));

    for (final Element element in swatches.evaluate()) {
      final SemanticsNode node = tester.getSemantics(find.byElementPredicate(
        (Element candidate) => identical(candidate, element),
      ));
      final SemanticsData data = node.getSemanticsData();

      expect(data.label, 'Orange');
      expect(
        data.tooltip,
        isEmpty,
        reason: 'the tooltip repeated the label, and on Android a tooltip '
            'rides alongside the content description rather than replacing it',
      );
      expect(node.flagsCollection.isButton, isTrue);
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'excluding the subtree must not cost the swatch its tap action',
      );
    }

    handle.dispose();
  });

  testWidgets('the visible tooltip is still there for the mouse',
      (tester) async {
    await _pump(tester);
    // Dropped from semantics, not from the widget tree.
    expect(find.byTooltip('Orange'), findsNWidgets(2));
  });

  testWidgets('a selected swatch says it is selected', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(tester);

    final Iterable<SemanticsNode> nodes = _swatchNodes(tester);
    expect(
      nodes.where(
          (SemanticsNode n) => n.flagsCollection.isSelected == Tristate.isTrue),
      isNotEmpty,
      reason: 'the chosen accent has to be distinguishable by ear',
    );

    handle.dispose();
  });
}

/// Every node that looks like an accent swatch: a button carrying one of the
/// palette's colour names.
Iterable<SemanticsNode> _swatchNodes(WidgetTester tester) {
  const Set<String> names = <String>{
    'Violet',
    'Orange',
    'Cyan',
    'Blue',
    'Teal',
    'Green',
    'Gold',
    'Pink',
    'Red',
    'White',
  };
  final List<SemanticsNode> found = <SemanticsNode>[];
  void walk(SemanticsNode node) {
    if (names.contains(node.getSemanticsData().label)) found.add(node);
    node.visitChildren((SemanticsNode child) {
      walk(child);
      return true;
    });
  }

  // Walked from the app's own node rather than the binding's semantics
  // owner, which is deprecated.
  walk(tester.getSemantics(find.byType(MaterialApp)));
  return found;
}
