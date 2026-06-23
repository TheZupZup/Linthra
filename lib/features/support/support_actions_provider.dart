import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'support_action.dart';

/// The distribution channel a build targets, used **only** to decide which
/// support actions to offer.
///
/// Read once from `--dart-define=LINTHRA_DISTRIBUTION=...` and defaulting to
/// [fdroid]. The default is the safe one: an ordinary `flutter build` — local,
/// CI, and the F-Droid build server alike — gets external donation links only
/// and never the Play billing seat, so F-Droid builds stay free of any
/// proprietary billing path. This mirrors how `AppInfo` reads its optional
/// `LINTHRA_VERSION_NAME` override from the environment.
enum SupportDistribution {
  /// F-Droid, dev, and GitHub-Release builds: external donation links only.
  fdroid,

  /// A future Play-Store-only build: keeps the links and adds a placeholder for
  /// the Google Play Billing supporter purchase a later, Play-only PR will
  /// implement. Selecting it today changes only which rows are listed; it adds
  /// no billing code or dependency.
  play;

  /// The channel this build was compiled for, from the dart-define (default
  /// [fdroid]).
  static SupportDistribution get current =>
      fromDefine(const String.fromEnvironment('LINTHRA_DISTRIBUTION'));

  /// Pure parser behind [current]: maps the dart-define string to a channel,
  /// falling back to [fdroid] for the empty or unknown value. Exposed so the
  /// mapping is unit-testable without recompiling under a dart-define.
  static SupportDistribution fromDefine(String value) {
    switch (value.trim().toLowerCase()) {
      case 'play':
      case 'playstore':
      case 'google':
        return SupportDistribution.play;
      default:
        return SupportDistribution.fdroid;
    }
  }
}

/// External destinations the support links point at, in one place so a
/// maintainer can update a handle without touching the screen.
///
/// Treat the donation handles as placeholders until the matching accounts are
/// live (see docs/SUPPORT.md): the screen and tests only assert that each link
/// is well-formed, never that an account exists.
abstract final class SupportLinks {
  /// GitHub Sponsors page for the project owner. Placeholder until Sponsors is
  /// enabled on the account.
  static const String gitHubSponsors = 'https://github.com/sponsors/thezupzup';

  /// The supporter-model doc shipped in this repository — what support funds,
  /// and how the F-Droid vs Play distinction works.
  static const String supporterModel =
      'https://github.com/thezupzup/linthra/blob/main/docs/SUPPORT.md';

  /// The public source repository — supporting by reading, building, starring,
  /// or contributing is always free.
  static const String sourceCode = 'https://github.com/thezupzup/linthra';
}

/// Builds the support actions offered for [distribution].
///
/// Pure and Flutter-light (only icon constants) so it is unit-testable without
/// a `ProviderScope`, a browser, or a build flavor. Every build gets the same
/// external links; the [SupportDistribution.play] channel additionally lists
/// the disabled "supporter purchase" placeholder that a future Play-only PR
/// will turn into a real Google Play Billing action. No billing code lives
/// here.
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

  // Reserved seat for Play Store supporter purchases. Listed only in a Play
  // build and only as a disabled "coming soon" row — the real Google Play
  // Billing action ships in a later, Play-only PR, so F-Droid never carries a
  // billing dependency.
  if (distribution == SupportDistribution.play) {
    actions.add(
      const SupportAction(
        id: 'play-supporter',
        title: 'Become a supporter',
        description: 'One-time supporter purchases are coming to the Play '
            'Store edition.',
        icon: Icons.workspace_premium_outlined,
        kind: SupportActionKind.comingSoon,
      ),
    );
  }

  return actions;
}

/// The support actions for the current build, read by `SupportScreen`.
///
/// This is the seam future builds extend: a Play-only build overrides this
/// provider (or relies on the [SupportDistribution.play] branch in
/// [supportActionsFor]) to surface its supporter purchase, while F-Droid and
/// dev builds keep the external links and nothing else. Declaring it as a
/// provider also lets widget tests inject a fixed list without a dart-define.
final supportActionsProvider = Provider<List<SupportAction>>(
  (ref) => supportActionsFor(SupportDistribution.current),
);
