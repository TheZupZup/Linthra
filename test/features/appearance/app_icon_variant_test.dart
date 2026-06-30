import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';

void main() {
  group('AppIconVariants catalog', () {
    test('Classic is the first/default variant', () {
      expect(AppIconVariants.all.first, AppIconVariants.classic);
      expect(AppIconVariants.classic.id, 'classic');
      expect(AppIconVariants.classic.tier, AppIconTier.free);
    });

    test('every variant id is unique', () {
      final List<String> ids =
          AppIconVariants.all.map((AppIconVariant v) => v.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every variant is well-formed (gradient + in-range bars)', () {
      for (final AppIconVariant variant in AppIconVariants.all) {
        expect(variant.id, isNotEmpty);
        expect(variant.label, isNotEmpty);
        expect(
          variant.gradient.length,
          greaterThanOrEqualTo(2),
          reason: '${variant.id} needs a gradient with at least two stops',
        );
        expect(variant.bars, isNotEmpty, reason: '${variant.id} needs bars');
        for (final double height in variant.bars) {
          expect(height, greaterThan(0));
          expect(height, lessThanOrEqualTo(1));
        }
      }
    });

    test('gold ships in the catalog and is free', () {
      expect(AppIconVariants.gold.tier, AppIconTier.free);
      // It ships in the catalog like any other variant — there is no gating
      // field anywhere, so nothing can lock it.
      expect(AppIconVariants.all, contains(AppIconVariants.gold));
    });

    test('every variant is free — no supporter-tier styles in this build', () {
      final List<AppIconVariant> supporters = AppIconVariants.all
          .where((AppIconVariant v) => v.tier == AppIconTier.supporter)
          .toList();
      expect(supporters, isEmpty);
    });
  });

  group('AppIconVariants.byId', () {
    test('resolves each known id to its variant', () {
      for (final AppIconVariant variant in AppIconVariants.all) {
        expect(AppIconVariants.byId(variant.id), variant);
      }
    });

    test('falls back to Classic for null, empty, or unknown ids', () {
      expect(AppIconVariants.byId(null), AppIconVariants.classic);
      expect(AppIconVariants.byId(''), AppIconVariants.classic);
      expect(AppIconVariants.byId('   '), AppIconVariants.classic);
      expect(AppIconVariants.byId('does-not-exist'), AppIconVariants.classic);
    });
  });
}
