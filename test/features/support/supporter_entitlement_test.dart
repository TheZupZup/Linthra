import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/support/github_sponsor_simulation.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

void main() {
  group('supporterEntitlementFor', () {
    test('F-Droid includes custom palette access for every define', () {
      for (final String value in <String>['', 'locked', 'unlocked', 'off']) {
        expect(
          supporterEntitlementFor(
            distribution: SupportDistribution.fdroid,
            accessDefine: value,
          ),
          SupporterEntitlement.included,
        );
      }
    });

    test('GitHub Release defaults to locked', () {
      expect(
        supporterEntitlementFor(
          distribution: SupportDistribution.githubRelease,
          accessDefine: '',
        ),
        SupporterEntitlement.locked,
      );
    });

    test('GitHub internal builds can force unlocked for testing', () {
      expect(
        supporterEntitlementFor(
          distribution: SupportDistribution.githubRelease,
          accessDefine: 'unlocked',
        ),
        SupporterEntitlement.unlocked,
      );
    });

    test('Play defaults to included until billing takes over', () {
      expect(
        supporterEntitlementFor(
          distribution: SupportDistribution.play,
          accessDefine: '',
        ),
        SupporterEntitlement.included,
      );
    });

    test('only locked access disables cosmetics', () {
      expect(SupporterEntitlement.included.allowsCosmetics, isTrue);
      expect(SupporterEntitlement.unlocked.allowsCosmetics, isTrue);
      expect(SupporterEntitlement.locked.allowsCosmetics, isFalse);
    });
  });

  group('githubSponsorSimulationFor', () {
    test('defaults to real GitHub verification', () {
      expect(
        githubSponsorSimulationFor(''),
        GitHubSponsorSimulation.real,
      );
      expect(
        githubSponsorSimulationFor('real'),
        GitHubSponsorSimulation.real,
      );
      expect(
        githubSponsorSimulationFor('unexpected'),
        GitHubSponsorSimulation.real,
      );
    });

    test('parses locked and unlocked simulation APK states', () {
      expect(
        githubSponsorSimulationFor('locked'),
        GitHubSponsorSimulation.locked,
      );
      expect(
        githubSponsorSimulationFor('UNLOCKED'),
        GitHubSponsorSimulation.unlocked,
      );
    });
  });
}
