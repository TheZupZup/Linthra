import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'support_action.dart';

/// The distribution channel a build targets, used **only** to decide which
/// support actions and optional cosmetic rewards to offer.
///
/// Read once from `--dart-define=LINTHRA_DISTRIBUTION=...` and defaulting to
/// [fdroid]. The default is the safe one: an ordinary `flutter build` — local,
/// CI, and the F-Droid build server alike — gets external donation links only
/// and never a proprietary billing path.
enum SupportDistribution {
  /// F-Droid, ordinary development builds, and the canonical reproducible APKs.
  /// The supporter-only custom palette is not offered in this distribution.
  fdroid,

  /// APK distributed directly through GitHub Releases. The custom palette is
  /// unlocked only after GitHub verifies an active monthly sponsorship of the
  /// maintainer account.
  githubRelease,

  /// A future Play-Store-only build. Google Play Billing remains a separate,
  /// Play-only concern and the custom palette stays unavailable until that
  /// integration exists.
  play;

  /// Whether this distribution may expose the supporter-only custom palette.
  bool get offersCustomPalette => this == SupportDistribution.githubRelease;

  /// The channel this build was compiled for, from the dart-define (default
  /// [fdroid]).
  static SupportDistribution get current =>
      fromDefine(const String.fromEnvironment('LINTHRA_DISTRIBUTION'));

  /// Pure parser behind [current].
  static SupportDistribution fromDefine(String value) {
    switch (value.trim().toLowerCase()) {
      case 'github':
      case 'github-release':
      case 'release':
      case 'apk':
        return SupportDistribution.githubRelease;
      case 'play':
      case 'playstore':
      case 'google':
        return SupportDistribution.play;
      default:
        return SupportDistribution.fdroid;
    }
  }
}

/// The current distribution behind a provider so feature modules and tests can
/// share one overridable build seam.
final supportDistributionProvider = Provider<SupportDistribution>(
  (ref) => SupportDistribution.current,
);

/// Whether this build offers any voluntary support links at all.
bool get supportLinksEnabled => supportLinksEnabledFromDefine(
      const String.fromEnvironment('LINTHRA_SUPPORT_LINKS'),
    );

/// Pure parser behind [supportLinksEnabled], defaulting to enabled.
bool supportLinksEnabledFromDefine(String value) {
  switch (value.trim().toLowerCase()) {
    case 'off':
    case 'false':
    case '0':
    case 'no':
    case 'disabled':
      return false;
    default:
      return true;
  }
}

/// External destinations the support links point at.
abstract final class SupportLinks {
  static const String gitHubSponsors = 'https://github.com/sponsors/thezupzup';

  static const String supporterModel =
      'https://github.com/thezupzup/linthra/blob/main/docs/SUPPORT.md';

  static const String sourceCode = 'https://github.com/thezupzup/linthra';
}

/// Builds the support actions offered for [distribution].
List<SupportAction> supportActionsFor(SupportDistribution distribution) {
  final List<SupportAction> actions = <SupportAction>[
    const SupportAction(
      id: 'github-sponsors',
      title: 'GitHub Sponsors',
      description: 'Sponsor Linthra on GitHub — one-off or monthly.',
      icon: Icons.favorite_outline,
      kind: SupportActionKind.externalLink,
      url: SupportLinks.gitHubSponsors,
    ),
    const SupportAction(
      id: 'supporter-model',
      title: 'Funding & supporter model',
      description: 'How support is used and what is planned.',
      icon: Icons.volunteer_activism_outlined,
      kind: SupportActionKind.externalLink,
      url: SupportLinks.supporterModel,
    ),
    const SupportAction(
      id: 'source-code',
      title: 'View source code',
      description: 'Linthra is open source — read, build, and contribute.',
      icon: Icons.code_outlined,
      kind: SupportActionKind.externalLink,
      url: SupportLinks.sourceCode,
    ),
  ];

  if (distribution == SupportDistribution.play) {
    actions.add(
      const SupportAction(
        id: 'play-supporter',
        title: 'Become a supporter',
        description: 'One-time supporter purchases are coming to the Play '
            'Store edition.',
        icon: Icons.card_giftcard_outlined,
        kind: SupportActionKind.comingSoon,
      ),
    );
  }

  return actions;
}

/// The support actions for the current build, read by `SupportScreen`.
final supportActionsProvider = Provider<List<SupportAction>>((ref) {
  if (!supportLinksEnabled) {
    return const <SupportAction>[];
  }
  return supportActionsFor(ref.watch(supportDistributionProvider));
});

/// Whether the in-app "Support Linthra" entry point should be shown.
final supportLinksEnabledProvider =
    Provider<bool>((ref) => supportLinksEnabled);
