import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'github_sponsor_controller.dart';
import 'github_sponsor_simulation.dart';
import 'support_actions_provider.dart';

/// Access state for optional cosmetic supporter rewards.
///
/// Core playback, offline, provider, Cast, Android Auto, and storage features
/// must never depend on this value. It exists only for the custom color palette.
enum SupporterEntitlement {
  /// The distribution includes the cosmetic without a purchase.
  ///
  /// Kept for focused internal tests and possible future store integrations;
  /// production F-Droid and Play builds do not return this state.
  included,

  /// The cosmetic is unavailable or visible but not owned.
  locked,

  /// The distribution has verified the required supporter access.
  unlocked;

  bool get allowsCosmetics => this != SupporterEntitlement.locked;
}

/// Parses the build-time entitlement used by tests.
///
/// Only the dedicated GitHub distribution may ever honor an override. F-Droid,
/// ordinary builds, and Play stay locked even if a stale or malicious define is
/// supplied.
SupporterEntitlement supporterEntitlementFor({
  required SupportDistribution distribution,
  required String accessDefine,
}) {
  if (!distribution.offersCustomPalette) {
    return SupporterEntitlement.locked;
  }

  final String normalized = accessDefine.trim().toLowerCase();
  switch (normalized) {
    case 'unlocked':
    case 'on':
    case 'true':
    case '1':
      return SupporterEntitlement.unlocked;
    case 'locked':
    case 'off':
    case 'false':
    case '0':
    default:
      return SupporterEntitlement.locked;
  }
}

/// The cosmetic supporter entitlement for this build.
///
/// GitHub Release APKs are locked by default and become unlocked only when the
/// signed-in account has an active monthly sponsorship at the required tier.
/// Dedicated simulation APKs can force locked/unlocked without contacting
/// GitHub. F-Droid, ordinary builds, and Play never expose this entitlement.
final supporterEntitlementProvider = Provider<SupporterEntitlement>((ref) {
  final SupportDistribution distribution =
      ref.watch(supportDistributionProvider);
  if (!distribution.offersCustomPalette) {
    return SupporterEntitlement.locked;
  }

  final GitHubSponsorSimulation simulation =
      ref.watch(githubSponsorSimulationProvider);
  switch (simulation) {
    case GitHubSponsorSimulation.locked:
      return SupporterEntitlement.locked;
    case GitHubSponsorSimulation.unlocked:
      return SupporterEntitlement.unlocked;
    case GitHubSponsorSimulation.real:
      final bool active = ref
              .watch(githubSponsorControllerProvider)
              .valueOrNull
              ?.hasActiveMonthlySponsorship ==
          true;
      return active
          ? SupporterEntitlement.unlocked
          : SupporterEntitlement.locked;
  }
});
