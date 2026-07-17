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

    test('Classic and Neon are always-free styles', () {
      expect(AppIconVariants.classic.tier, AppIconTier.free);
      expect(AppIconVariants.neon.tier, AppIconTier.free);
    });

    test('Gold and Black & White are supporter cosmetics', () {
      final List<AppIconVariant> supporters = AppIconVariants.all
          .where((AppIconVariant v) => v.tier == AppIconTier.supporter)
          .toList();

      expect(
        supporters,
        <AppIconVariant>[
          AppIconVariants.gold,
          AppIconVariants.blackWhite,
        ],
      );
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
