import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../support/supporter_entitlement.dart';
import 'app_icon_variant.dart';

/// Whether a branding variant can be selected in the current build.
enum AppIconAccess {
  available,
  supporterRequired;

  bool get canSelect => this == AppIconAccess.available;
}

/// Pure access policy for branding variants.
///
/// Free variants are always available. Supporter variants are available when
/// the current distribution includes them or when a Play purchase has been
/// verified. This policy must remain cosmetic-only.
AppIconAccess appIconAccessFor(
  AppIconVariant variant,
  SupporterEntitlement entitlement,
) {
  if (variant.tier == AppIconTier.free || entitlement.allowsCosmetics) {
    return AppIconAccess.available;
  }
  return AppIconAccess.supporterRequired;
}

/// Access state for one branding variant.
final appIconAccessProvider =
    Provider.family<AppIconAccess, AppIconVariant>((ref, variant) {
  final SupporterEntitlement entitlement =
      ref.watch(supporterEntitlementProvider);
  return appIconAccessFor(variant, entitlement);
});
