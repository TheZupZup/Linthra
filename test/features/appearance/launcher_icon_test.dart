import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';
import 'package:linthra/features/appearance/launcher_icon.dart';

void main() {
  group('LauncherIconAliases', () {
    test('maps every branding variant 1:1 to a launcher alias', () {
      // Same count and same ids, in the same order — so a new AppIconVariant
      // can never silently ship without a launcher icon (and vice versa).
      expect(
        LauncherIconAliases.all.length,
        AppIconVariants.all.length,
        reason: 'every variant needs exactly one launcher alias',
      );
      for (var i = 0; i < AppIconVariants.all.length; i++) {
        expect(
          LauncherIconAliases.all[i].variantId,
          AppIconVariants.all[i].id,
          reason: 'alias order/ids must match AppIconVariants',
        );
      }
      // Every variant resolves to an alias whose variantId points back at it.
      for (final AppIconVariant variant in AppIconVariants.all) {
        expect(
          LauncherIconAliases.byVariantId(variant.id).variantId,
          variant.id,
        );
      }
    });

    test('alias names are non-empty, unique, and Icon-prefixed', () {
      final Set<String> names = <String>{};
      for (final LauncherIconAlias alias in LauncherIconAliases.all) {
        expect(alias.aliasName, isNotEmpty);
        // Mirrors the manifest <activity-alias android:name=".Icon…"> scheme and
        // the Kotlin channel's ALIASES list.
        expect(alias.aliasName, startsWith('Icon'));
        expect(
          names.add(alias.aliasName),
          isTrue,
          reason: '${alias.aliasName} is duplicated',
        );
      }
    });

    test('exactly one alias is the default, and it is Classic', () {
      final Iterable<LauncherIconAlias> defaults =
          LauncherIconAliases.all.where((LauncherIconAlias a) => a.isDefault);
      expect(defaults.length, 1);
      expect(defaults.single.variantId, AppIconVariants.classic.id);
      expect(LauncherIconAliases.defaultAlias, LauncherIconAliases.classic);
      expect(LauncherIconAliases.classic.aliasName, 'IconClassic');
    });

    test('byVariantId falls back to the default for null/empty/unknown', () {
      // The same "unknown → Classic" rule AppIconVariants.byId follows, so the
      // launcher never lands on an icon with no asset.
      expect(
        LauncherIconAliases.byVariantId(null),
        LauncherIconAliases.defaultAlias,
      );
      expect(
        LauncherIconAliases.byVariantId(''),
        LauncherIconAliases.defaultAlias,
      );
      expect(
        LauncherIconAliases.byVariantId('totally-bogus'),
        LauncherIconAliases.defaultAlias,
      );
    });

    test('resolves each known variant id to its own alias', () {
      expect(LauncherIconAliases.byVariantId('neon').aliasName, 'IconNeon');
      expect(LauncherIconAliases.byVariantId('gold').aliasName, 'IconGold');
      expect(
        LauncherIconAliases.byVariantId('dark').aliasName,
        'IconDark',
      );
    });
  });
}
