import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'github_sponsor_controller.dart';
import 'support_actions_provider.dart';

/// Access state for optional cosmetic supporter rewards.
///
/// Core playback, offline, provider, Cast, Android Auto, and storage features
/// must never depend on this value. It exists only for the custom color palette.
enum SupporterEntitlement {
  /// The distribution includes the cosmetic without a purchase.
  included,

  /// The cosmetic is visible but not owned.
  locked,

  /// The distribution has verified the required supporter access.
  unlocked;

  bool get allowsCosmetics => this != SupporterEntitlement.locked;
}

/// Parses the build-time entitlement used by tests and non-GitHub channels.
SupporterEntitlement supporterEntitlementFor({
  required SupportDistribution distribution,
  required String accessDefine,
}) {
  if (distribution == SupportDistribution.fdroid) {
    return SupporterEntitlement.included;
  }

  final String normalized = accessDefine.trim().toLowerCase();
  switch (normalized) {
    case 'locked':
    case 'off':
    case 'false':
    case '0':
      return SupporterEntitlement.locked;
    case 'unlocked':
    case 'on':
    case 'true':
    case '1':
      return SupporterEntitlement.unlocked;
    default:
      return distribution == SupportDistribution.githubRelease
          ? SupporterEntitlement.locked
          : SupporterEntitlement.included;
  }
}

/// The cosmetic supporter entitlement for this build.
///
/// GitHub Release APKs are locked by default and become unlocked only when the
/// signed-in account has an active monthly sponsorship. F-Droid includes the
/// palette. Play remains billing-SDK agnostic until a separate integration is
/// implemented.
final supporterEntitlementProvider = Provider<SupporterEntitlement>((ref) {
  final SupportDistribution distribution =
      ref.watch(supportDistributionProvider);
  if (distribution == SupportDistribution.githubRelease) {
    final bool active = ref
            .watch(githubSponsorControllerProvider)
            .valueOrNull
            ?.hasActiveMonthlySponsorship ==
        true;
    return active ? SupporterEntitlement.unlocked : SupporterEntitlement.locked;
  }

  return supporterEntitlementFor(
    distribution: distribution,
    accessDefine: const String.fromEnvironment('LINTHRA_SUPPORTER_COSMETICS'),
  );
});
