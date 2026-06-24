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
  ///
  /// Store-policy note: a Play build may need to handle the **external**
  /// donation links differently from F-Droid — Google Play's payments policy can
  /// restrict linking out to donations for non-charity developers. The Play-only
  /// PR should adjust those links per policy (e.g. route supporters to Play
  /// Billing instead), and `LINTHRA_SUPPORT_LINKS=off` can drop the external
  /// links entirely for a channel that forbids them. See docs/SUPPORT.md §6.
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

/// Whether this build offers any voluntary support links at all.
///
/// Read once from `--dart-define=LINTHRA_SUPPORT_LINKS=...`, **defaulting to
/// enabled**, and parsed by [supportLinksEnabledFromDefine]. Build with
/// `--dart-define=LINTHRA_SUPPORT_LINKS=off` (also: `false`, `0`, `no`,
/// `disabled`) to compile an edition with the in-app "Support Linthra" entry
/// point and every external donation link removed entirely.
///
/// This is the per-channel kill switch the audit asks for: it is the seam for a
/// distribution channel whose policy forbids in-app donation links (some app
/// stores restrict linking out to donations for non-charity developers — see
/// docs/SUPPORT.md §6), or for a fork that wants none. Like
/// [SupportDistribution] it is read from the environment and is **support-only**:
/// it changes nothing but which support actions (if any) are offered, and never
/// touches playback, caching, providers, Android Auto, Cast, Backup/Restore, or
/// any other app behavior.
bool get supportLinksEnabled => supportLinksEnabledFromDefine(
      const String.fromEnvironment('LINTHRA_SUPPORT_LINKS'),
    );

/// Pure parser behind [supportLinksEnabled]: maps the dart-define string to a
/// flag, **defaulting to enabled** for the empty or unknown value so an ordinary
/// `flutter build` keeps the links. Exposed so the mapping is unit-testable
/// without recompiling under a dart-define.
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
        icon: Icons.card_giftcard_outlined,
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
///
/// When [supportLinksEnabled] is false (the per-channel kill switch) this yields
/// an empty list, so a build compiled with `LINTHRA_SUPPORT_LINKS=off` offers no
/// support actions at all and the screen degrades to a purely informational
/// page.
final supportActionsProvider = Provider<List<SupportAction>>(
  (ref) => supportLinksEnabled
      ? supportActionsFor(SupportDistribution.current)
      : const <SupportAction>[],
);

/// Whether the in-app "Support Linthra" entry point should be shown.
///
/// Mirrors [supportLinksEnabled] behind a provider so the About page can hide
/// its "Support Linthra" card in a links-disabled build, and so widget tests can
/// flip the switch without a dart-define. Reads the same env flag, so the entry
/// point and the actions are always consistent.
final supportLinksEnabledProvider =
    Provider<bool>((ref) => supportLinksEnabled);
