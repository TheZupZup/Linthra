import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

void main() {
  group('supporterEntitlementFor', () {
    test('F-Droid includes custom palette access for every define', () {
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

    test('only locked access disables cosmetics', () {
      expect(SupporterEntitlement.included.allowsCosmetics, isTrue);
      expect(SupporterEntitlement.unlocked.allowsCosmetics, isTrue);
      expect(SupporterEntitlement.locked.allowsCosmetics, isFalse);
    });
  });
}
