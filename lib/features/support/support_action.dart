import 'package:flutter/material.dart';

/// How a [SupportAction] behaves when the user taps it.
///
/// A small, closed set so the Support screen can render any action uniformly
/// and never embeds donation or payment logic itself (the product rule). A
/// future build adds a new kind for its channel — e.g. a Google Play Billing
/// supporter purchase — and supplies the matching set through
/// `supportActionsProvider`, rather than the screen growing platform-specific
/// branches.
enum SupportActionKind {
  /// Opens an external page in the browser through the shared
  /// `externalLinkLauncherProvider` seam (GitHub Sponsors, the funding/supporter
  /// doc, the source repository). The only kind F-Droid and dev builds offer
  /// today, and the only kind that ever ships in an F-Droid build: it pulls in
  /// no billing dependency.
  externalLink,

  /// A reserved, non-actionable placeholder shown disabled with a short
  /// "coming soon" hint. It is the seat held for Google Play Billing supporter
  /// purchases, which are implemented only in a future Play-only build; the
  /// placeholder itself carries no billing code, so it is safe in every build.
  comingSoon,
}

/// One voluntary way to support Linthra's development, described as plain data.
///
/// The Support feature is deliberately data-driven: `supportActionsProvider`
/// assembles the right list for the current build (external links for
/// F-Droid/dev, with room for a Play supporter purchase later) and
/// `SupportScreen` renders whatever it is given. Keeping actions as data — not
/// hard-coded widgets — is what lets future builds swap the set without
/// touching the screen, and keeps the whole feature unit-testable without a
/// real browser or store.
class SupportAction {
  const SupportAction({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.kind,
    this.url,
  }) : assert(
          kind != SupportActionKind.externalLink || url != null,
          'An externalLink action must carry the URL to open.',
        );

  /// Stable identifier, handy for widget keys and tests. Never shown to users.
  final String id;

  /// Short, scannable label for the action (e.g. "GitHub Sponsors").
  final String title;

  /// One line under the [title] explaining what the action does.
  final String description;

  /// Leading glyph for the row.
  final IconData icon;

  /// What happens on tap — see [SupportActionKind].
  final SupportActionKind kind;

  /// The page to open for a [SupportActionKind.externalLink] action; null for
  /// every other kind. Exposed as a parsed [uri] so the screen never parses raw
  /// strings.
  final String? url;

  /// The [url] as a [Uri], or null when this action has none.
  Uri? get uri => url == null ? null : Uri.parse(url!);
}

/// Whether [uri] is safe for the Support screen to hand to the external browser
/// launcher: a non-empty `http`/`https` web link and nothing else.
///
/// Defense in depth. Every link that ships today is an `https` constant in
/// `SupportLinks`, so in a correct build this always passes; the guard exists so
/// that a future mis-edited link carrying a non-web scheme — a `tel:`,
/// `mailto:`, `file:`, `javascript:`, or a custom app-intent URI — fails *safe*:
/// the screen declines to launch it rather than handing an unexpected scheme to
/// the OS. It is the runtime backstop to the compile-time `https` check the
/// support-links test enforces, and it is pure so it is unit-testable without a
/// widget or a real launcher.
bool isLaunchableHttpUrl(Uri? uri) =>
    uri != null &&
    (uri.isScheme('https') || uri.isScheme('http')) &&
    uri.host.isNotEmpty;
