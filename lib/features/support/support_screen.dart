import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../app/external_link_launcher_provider.dart';
import 'support_action.dart';
import 'support_actions_provider.dart';

/// The "Support Linthra" screen, reached from Settings → About.
///
/// Linthra is free and open source and stays that way: this screen exists only
/// to make *voluntary* support easy to find. It states plainly that support is
/// optional and that every core feature stays free, explains where
/// contributions go (development, testing devices, app-store costs, and
/// long-term maintenance), and lists a few ways to help.
///
/// It owns no donation or payment logic. The actions come from
/// [supportActionsProvider] — external links for F-Droid and dev builds, with a
/// disabled placeholder reserved for a future Play Store supporter purchase —
/// and links open through the shared [externalLinkLauncherProvider], the same
/// browser seam the About page uses, so every launch is an explicit tap and
/// widget tests stay plugin-free.
class SupportScreen extends ConsumerWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<SupportAction> actions = ref.watch(supportActionsProvider);
    // A links-disabled build (LINTHRA_SUPPORT_LINKS=off) yields no actions; the
    // screen then degrades to a purely informational page — the free/optional
    // copy with no actions card and no call-to-action aside.
    final bool hasActions = actions.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Support Linthra')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: <Widget>[
          const _IntroCard(),
          if (hasActions) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _ActionsCard(
              actions: actions,
              onOpenLink: (SupportAction action) =>
                  _openLink(context, ref, action),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          const _FreeForeverNote(),
          if (hasActions) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            const _LonelyMaintainerNote(),
          ],
        ],
      ),
    );
  }

  /// Opens an [SupportActionKind.externalLink] action through the shared
  /// launcher, falling back to a snackbar if the platform can't (the launcher
  /// never throws). The messenger is captured before the await so we don't
  /// touch [context] across an async gap — the same guard the About page uses.
  Future<void> _openLink(
    BuildContext context,
    WidgetRef ref,
    SupportAction action,
  ) async {
    final Uri? url = action.uri;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // Only ever hand the OS an http(s) web link. A correct build always passes
    // this (every shipped link is an https constant in SupportLinks); the guard
    // makes a mis-edited non-web link fail safe — we decline rather than launch
    // an unexpected scheme.
    if (!isLaunchableHttpUrl(url)) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open the link.")),
      );
      return;
    }
    final bool launched =
        await ref.read(externalLinkLauncherProvider).open(url!);
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open the link.")),
      );
    }
  }
}

/// The explanatory header: Linthra is free and open source, support is
/// optional, and a short list of where support goes.
class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.favorite_outline,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Linthra is free and open source',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Supporting Linthra is completely optional and never required. '
              'Every feature is free, with no ads and no tracking — support '
              'simply helps the project keep going.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'No ads. No tracking. No locked core features.',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Donating does not unlock features — core playback and '
              'self-hosted music features stay free.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Where your support goes',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _SupportUse(
              icon: Icons.build_outlined,
              text: 'Development and new features',
            ),
            const _SupportUse(
              icon: Icons.phone_android_outlined,
              text: 'Testing devices',
            ),
            const _SupportUse(
              icon: Icons.storefront_outlined,
              text: 'App store and distribution costs',
            ),
            const _SupportUse(
              icon: Icons.update_outlined,
              text: 'Long-term maintenance',
            ),
          ],
        ),
      ),
    );
  }
}

/// A single "where your support goes" line: a muted glyph and a label.
class _SupportUse extends StatelessWidget {
  const _SupportUse({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: muted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Callback a support row uses to open its external link, wired by the screen.
typedef _OpenSupportLink = void Function(SupportAction action);

/// The card listing the support actions, one row each with dividers between.
class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.actions, required this.onOpenLink});

  final List<SupportAction> actions;
  final _OpenSupportLink onOpenLink;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (final SupportAction action in actions) {
      if (rows.isNotEmpty) {
        rows.add(const Divider(height: 0));
      }
      rows.add(_SupportActionRow(action: action, onOpenLink: onOpenLink));
    }
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

/// One support action rendered by its [SupportActionKind]: a tappable external
/// link, or a disabled "coming soon" placeholder. The row interprets only the
/// generic kind — never which build it is or any payment behaviour — so the
/// screen stays free of platform-specific donation logic.
class _SupportActionRow extends StatelessWidget {
  const _SupportActionRow({required this.action, required this.onOpenLink});

  final SupportAction action;
  final _OpenSupportLink onOpenLink;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    switch (action.kind) {
      case SupportActionKind.externalLink:
        return ListTile(
          leading: Icon(action.icon, color: theme.colorScheme.primary),
          title: Text(action.title),
          subtitle: Text(action.description),
          trailing: Icon(Icons.open_in_new, size: 18, color: muted),
          onTap: () => onOpenLink(action),
        );
      case SupportActionKind.comingSoon:
        return ListTile(
          enabled: false,
          leading: Icon(action.icon, color: muted),
          title: Text(action.title),
          subtitle: Text(action.description),
          trailing: Text(
            'Coming soon',
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
        );
    }
  }
}

/// A closing reassurance: support never gates anything — the core stays free.
class _FreeForeverNote extends StatelessWidget {
  const _FreeForeverNote();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.lock_open_outlined, size: 18, color: muted),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'All core features stay free and unlocked. Support never gates '
            'anything, unlocks nothing, and changes nothing about how the app '
            'works.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// A small, deliberately secondary and playful aside beneath the serious
/// explanation. It is tone only: it sits at the bottom (never the headline),
/// is rendered inline (never a popup), blocks no navigation, gates and unlocks
/// nothing, and keeps "No pressure" in view so it never reads as a guilt-trip.
class _LonelyMaintainerNote extends StatelessWidget {
  const _LonelyMaintainerNote();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color faint = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    return Card(
      elevation: 0,
      color: theme.colorScheme.primary.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              "I'm lonely… I'm so lonely… I got nobody 🥺",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: faint,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Nobody to help me keep Linthra alive except you.',
              style: theme.textTheme.bodySmall?.copyWith(color: faint),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Kept the most readable line of the aside so the reassurance — not
            // the lament — is what stands out.
            Text(
              'No pressure. Just support if you want to help this lonely '
              'maintainer build something cool. ❤️',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
