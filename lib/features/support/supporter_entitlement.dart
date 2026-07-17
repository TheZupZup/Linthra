import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'support_actions_provider.dart';

/// Access state for optional cosmetic supporter rewards.
///
/// Core playback, offline, provider, Cast, Android Auto, and storage features
/// must never depend on this value. It exists only for visual rewards such as
/// alternate themes and launcher icons.
enum SupporterEntitlement {
  /// The distribution includes every cosmetic style without a purchase.
  included,

  /// The Play edition can show supporter cosmetics, but they are not owned.
  locked,

  /// The Play edition has confirmed the supporter purchase.
  unlocked;

  bool get allowsCosmetics => this != SupporterEntitlement.locked;
}

/// Parses the temporary build-time entitlement used by internal Play testing.
///
/// The default is [SupporterEntitlement.included] so existing builds preserve
/// today's behaviour until Play Billing replaces this seam. F-Droid always
/// returns [SupporterEntitlement.included], regardless of the define.
SupporterEntitlement supporterEntitlementFor({
  required SupportDistribution distribution,
  required String playAccessDefine,
}) {
  if (distribution == SupportDistribution.fdroid) {
    return SupporterEntitlement.included;
  }

  switch (playAccessDefine.trim().toLowerCase()) {
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
      return SupporterEntitlement.included;
  }
}

/// The cosmetic supporter entitlement for this build.
///
/// A future Play-only billing integration should override this provider with
/// verified purchase state. Keeping the provider in the shared app means the
/// appearance feature remains billing-SDK agnostic and F-Droid-safe.
final supporterEntitlementProvider = Provider<SupporterEntitlement>((ref) {
  final SupportDistribution distribution =
      ref.watch(supportDistributionProvider);
  return supporterEntitlementFor(
    distribution: distribution,
    playAccessDefine:
        const String.fromEnvironment('LINTHRA_SUPPORTER_COSMETICS'),
  );
});
