import 'package:flutter/foundation.dart';

import 'app_icon_variant.dart';

/// Maps a branding [AppIconVariant] to the Android `<activity-alias>` that
/// supplies its real launcher icon.
///
/// Each entry pairs a variant [variantId] with the manifest alias's *simple*
/// name (e.g. `IconNeon`). The native side composes the full component name as
/// `<applicationId>.<aliasName>` (see `LauncherIconChannel.kt`), so this list is
/// the single, auditable contract between the Dart catalog
/// ([AppIconVariants]) and `android/app/src/main/AndroidManifest.xml`. Keeping
/// it pure data makes the mapping trivially unit-testable with no platform.
@immutable
class LauncherIconAlias {
  const LauncherIconAlias({
    required this.variantId,
    required this.aliasName,
    this.isDefault = false,
  });

  /// The [AppIconVariant.id] this alias renders. One alias per variant.
  final String variantId;

  /// The manifest `<activity-alias>` simple name (no package prefix), e.g.
  /// `IconClassic`. The native channel prefixes it with the applicationId.
  final String aliasName;

  /// Whether this is the icon shipped enabled in the manifest and the fallback
  /// for an unknown/absent selection. Exactly one alias is the default.
  final bool isDefault;
}

/// The Android launcher-icon aliases, one per [AppIconVariants] variant.
///
/// The order and ids mirror [AppIconVariants.all]; a unit test asserts the two
/// stay 1:1 so a new variant can never silently lack a launcher icon. The alias
/// names match the `<activity-alias android:name=".Icon…">` entries in the
/// manifest.
abstract final class LauncherIconAliases {
  static const LauncherIconAlias classic = LauncherIconAlias(
    variantId: 'classic',
    aliasName: 'IconClassic',
    isDefault: true,
  );
  static const LauncherIconAlias dark =
      LauncherIconAlias(variantId: 'dark', aliasName: 'IconDark');
  static const LauncherIconAlias neon =
      LauncherIconAlias(variantId: 'neon', aliasName: 'IconNeon');
  static const LauncherIconAlias server =
      LauncherIconAlias(variantId: 'server', aliasName: 'IconServer');
  static const LauncherIconAlias waveform =
      LauncherIconAlias(variantId: 'waveform', aliasName: 'IconWaveform');
  static const LauncherIconAlias lonely =
      LauncherIconAlias(variantId: 'lonely', aliasName: 'IconLonely');
  static const LauncherIconAlias gold =
      LauncherIconAlias(variantId: 'gold', aliasName: 'IconGold');
  static const LauncherIconAlias monochrome = LauncherIconAlias(
    variantId: 'monochrome',
    aliasName: 'IconMonochrome',
  );
  static const LauncherIconAlias blackWhite = LauncherIconAlias(
    variantId: 'blackwhite',
    aliasName: 'IconBlackWhite',
  );

  /// Every alias in display order; Classic (the default) first.
  static const List<LauncherIconAlias> all = <LauncherIconAlias>[
    classic,
    dark,
    neon,
    server,
    waveform,
    lonely,
    gold,
    monochrome,
    blackWhite,
  ];

  /// The alias shipped enabled in the manifest and used as the fallback.
  static const LauncherIconAlias defaultAlias = classic;

  /// Resolves a stored/selected variant [id] to its alias, falling back to the
  /// [defaultAlias] (Classic) for a null, empty, or unrecognised value — the
  /// same "unknown → Classic" rule [AppIconVariants.byId] follows, so the
  /// launcher never lands on an icon that has no asset.
  static LauncherIconAlias byVariantId(String? id) {
    if (id == null || id.isEmpty) {
      return defaultAlias;
    }
    for (final LauncherIconAlias alias in all) {
      if (alias.variantId == id) {
        return alias;
      }
    }
    return defaultAlias;
  }
}
