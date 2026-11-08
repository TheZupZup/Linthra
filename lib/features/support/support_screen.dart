import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../app/external_link_launcher_provider.dart';
import '../../core/models/github_device_authorization.dart';
import '../../core/models/github_sponsor_status.dart';
import 'github_sponsor_controller.dart';
import 'github_sponsor_unlock_dialog.dart';
import 'support_action.dart';
import 'support_actions_provider.dart';

/// Voluntary support options for Linthra.
///
/// Core music features remain free. Only the dedicated GitHub Sponsor APK may
/// thank active monthly GitHub Sponsors with an optional custom color palette.
class SupportScreen extends ConsumerWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<SupportAction> actions = ref.watch(supportActionsProvider);
    final bool hasActions = actions.isNotEmpty;

    final SupportDistribution distribution =
        ref.watch(supportDistributionProvider);

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
          if (distribution == SupportDistribution.play) ...<Widget>[
            const _PlayGitHubAccountCard(),
            const SizedBox(height: AppSpacing.md),
          ],
          const SizedBox(height: AppSpacing.md),
          const _CoreFeaturesNote(),
        ],
      ),
    );
  }

  Future<void> _openLink(
    BuildContext context,
    WidgetRef ref,
    SupportAction action,
  ) async {
    final Uri? url = action.uri;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
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
              'Every core music feature is free, with no ads and no tracking — '
              'support simply helps the project keep going.',
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
              'In the dedicated GitHub Sponsor APK, an active monthly GitHub '
              'sponsorship unlocks the custom color palette. Classic, Neon, Gold, '
              'and Black & White icon themes stay free, alongside playback, '
              'offline listening, server connections, and Android Auto. F-Droid '
              'and the canonical reproducible APKs do not include the supporter '
              'palette or GitHub sign-in.',
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

typedef _OpenSupportLink = void Function(SupportAction action);

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

class _CoreFeaturesNote extends StatelessWidget {
  const _CoreFeaturesNote();

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
            'All core features and built-in icon themes stay free and unlocked. '
            'GitHub sponsorship may unlock the custom palette in the dedicated '
            'GitHub Sponsor APK only — never change how the app plays, syncs, '
            'caches, or connects to your music.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

class _PlayGitHubAccountCard extends ConsumerWidget {
  const _PlayGitHubAccountCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sponsor = ref.watch(githubSponsorControllerProvider);
    final status = sponsor.valueOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'GitHub Sponsor account',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Already a GitHub Sponsor? Connect your account '
              'to verify your sponsorship.',
            ),
            if (status?.hasActiveMonthlySponsorship == true)
              const Text('Monthly sponsorship verified.'),
            if (status?.message != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Text(
                status!.message!,
                key: const Key('support-github-status-message'),
              ),
            ],
            if (status?.connected != true)
              FilledButton.icon(
                key: const Key('support-connect-github'),
                onPressed: sponsor.isLoading ||
                        status?.access == GitHubSponsorAccess.checking ||
                        status?.access == GitHubSponsorAccess.unavailable
                    ? null
                    : () => _connectGitHub(context, ref),
                icon: const Icon(Icons.login),
                label: const Text('Connect GitHub'),
              )
            else
              Wrap(
                spacing: AppSpacing.sm,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('support-refresh-github'),
                    onPressed: sponsor.isLoading ||
                            status?.access == GitHubSponsorAccess.checking
                        ? null
                        : () => ref
                            .read(githubSponsorControllerProvider.notifier)
                            .refresh(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check again'),
                  ),
                  TextButton.icon(
                    key: const Key('support-disconnect-github'),
                    onPressed: sponsor.isLoading ||
                            status?.access == GitHubSponsorAccess.checking
                        ? null
                        : () => ref
                            .read(githubSponsorControllerProvider.notifier)
                            .disconnect(),
                    icon: const Icon(Icons.logout),
                    label: const Text('Disconnect GitHub'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _connectGitHub(BuildContext context, WidgetRef ref) async {
    final GitHubSponsorController controller =
        ref.read(githubSponsorControllerProvider.notifier);

    try {
      final GitHubDeviceAuthorization authorization =
          await controller.beginAuthorization();

      if (!context.mounted) {
        controller.cancelAuthorization();
        return;
      }

      final bool? verified = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => GitHubSponsorUnlockDialog(
          authorization: authorization,
        ),
      );

      if (verified != true) {
        controller.cancelAuthorization();
      }
    } on Object {
      if (!context.mounted) return;

      final String message =
          ref.read(githubSponsorControllerProvider).valueOrNull?.message ??
              'Could not start GitHub authorization.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }
}
