import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/appearance/app_icon_access.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

void main() {
  group('supporterEntitlementFor', () {
    test('F-Droid includes supporter cosmetics for every define', () {
      for (final String value in <String>['', 'locked', 'unlocked', 'off']) {
        expect(
          supporterEntitlementFor(
            distribution: SupportDistribution.fdroid,
            playAccessDefine: value,
          ),
          SupporterEntitlement.included,
        );
      }
    });

    test('Play defaults to included until billing takes over', () {
      expect(
        supporterEntitlementFor(
          distribution: SupportDistribution.play,
          playAccessDefine: '',
        ),
        SupporterEntitlement.included,
      );
    });

    test('Play internal builds can exercise locked and unlocked states', () {
      expect(
        supporterEntitlementFor(
          distribution: SupportDistribution.play,
          playAccessDefine: 'locked',
        ),
        SupporterEntitlement.locked,
      );
      expect(
        supporterEntitlementFor(
          distribution: SupportDistribution.play,
          playAccessDefine: 'unlocked',
        ),
        SupporterEntitlement.unlocked,
      );
    });
  });

  group('appIconAccessFor', () {
    test('free styles are always selectable', () {
      expect(
        appIconAccessFor(
          AppIconVariants.classic,
          SupporterEntitlement.locked,
        ),
        AppIconAccess.available,
      );
      expect(
        appIconAccessFor(
          AppIconVariants.neon,
          SupporterEntitlement.locked,
        ),
        AppIconAccess.available,
      );
    });

    test('supporter styles require entitlement only in the locked state', () {
      expect(
        appIconAccessFor(
          AppIconVariants.gold,
          SupporterEntitlement.locked,
        ),
        AppIconAccess.supporterRequired,
      );
      expect(
        appIconAccessFor(
          AppIconVariants.gold,
          SupporterEntitlement.included,
        ),
        AppIconAccess.available,
      );
      expect(
        appIconAccessFor(
          AppIconVariants.blackWhite,
          SupporterEntitlement.unlocked,
        ),
        AppIconAccess.available,
      );
    });
  });
}
