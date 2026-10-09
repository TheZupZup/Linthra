import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/app_icon_variant_store_provider.dart';
import 'package:linthra/data/repositories/custom_theme_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_app_icon_variant_store.dart';
import 'package:linthra/data/repositories/in_memory_custom_theme_store.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';
import 'package:linthra/features/appearance/appearance_settings_screen.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

/// Which app icon is in use was shown by a border and a check badge only
/// (#460). A screen reader heard four identical tiles and had no way to tell
/// which one was picked.

Future<void> _pump(WidgetTester tester, String selectedId) async {
  tester.view.physicalSize = const Size(1200, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appIconVariantStoreProvider
            .overrideWithValue(InMemoryAppIconVariantStore(selectedId)),
        customThemeStoreProvider.overrideWithValue(InMemoryCustomThemeStore()),
        supporterEntitlementProvider
            .overrideWithValue(SupporterEntitlement.locked),
        supportDistributionProvider
            .overrideWithValue(SupportDistribution.fdroid),
      ],
      child: const MaterialApp(home: AppearanceSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// The one semantics node that names [variant]'s tile.
SemanticsData _tile(AppIconVariant variant) {
  final Iterable<SemanticsNode> nodes = find.semantics
      .byPredicate(
        (SemanticsNode node) => node.label.split('\n').contains(variant.label),
      )
      .evaluate();
  expect(nodes, hasLength(1), reason: variant.label);
  return nodes.single.getSemanticsData();
}

void main() {
  testWidgets('the icon in use says it is selected, and only that one',
      (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(tester, AppIconVariants.neon.id);

    for (final AppIconVariant variant in AppIconVariants.all) {
      final SemanticsData tile = _tile(variant);
      expect(tile.flagsCollection.isButton, isTrue, reason: variant.label);
      expect(tile.hasAction(SemanticsAction.tap), isTrue,
          reason: variant.label);
      expect(
        tile.flagsCollection.isSelected,
        variant == AppIconVariants.neon ? Tristate.isTrue : Tristate.isFalse,
        reason: variant.label,
      );
    }
    handle.dispose();
  });
}
