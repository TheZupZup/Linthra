import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/custom_theme_settings.dart';
import '../../core/models/github_device_authorization.dart';
import '../../core/models/github_sponsor_status.dart';
import '../support/github_sponsor_controller.dart';
import '../support/github_sponsor_unlock_dialog.dart';
import '../support/support_actions_provider.dart';
import '../support/supporter_entitlement.dart';
import 'custom_theme_controller.dart';

/// Appearance controls for Linthra's optional two-color custom palette.
class CustomThemeCard extends ConsumerWidget {
  const CustomThemeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CustomThemeSettings settings =
        ref.watch(customThemeControllerProvider);
    final SupporterEntitlement entitlement =
        ref.watch(supporterEntitlementProvider);
    final SupportDistribution distribution =
        ref.watch(supportDistributionProvider);
    final CustomThemeController controller =
        ref.read(customThemeControllerProvider.notifier);
    final bool canCustomize = entitlement.allowsCosmetics;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Header(
              entitlement: entitlement,
              distribution: distribution,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Choose separate colors for Linthra’s identity and playback '
              'accent. This changes appearance only — never music features.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.65),
                  ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (!canCustomize)
              _LockedContent(distribution: distribution)
            else ...<Widget>[
              if (distribution == SupportDistribution.githubRelease)
                const _VerifiedGitHubSponsorRow(),
              SwitchListTile(
                key: const Key('custom-theme-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Use custom palette'),
                subtitle: const Text(
                  'Override the colors selected by the app icon theme.',
                ),
                value: settings.enabled,
                onChanged: (bool enabled) {
                  controller.setEnabled(enabled);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              _ColorSelector(
                label: 'Identity color',
                roleKey: 'primary',
                selectedValue: settings.primaryColorValue,
                onSelected: (int value) {
                  controller.setPrimaryColor(value);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              _ColorSelector(
                label: 'Playback accent',
                roleKey: 'accent',
                selectedValue: settings.accentColorValue,
                onSelected: (int value) {
                  controller.setAccentColor(value);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('custom-theme-reset'),
                  onPressed: settings == CustomThemeSettings.defaults
                      ? null
                      : () {
                          controller.reset();
                        },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset colors'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.entitlement,
    required this.distribution,
  });

  final SupporterEntitlement entitlement;
  final SupportDistribution distribution;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String badge = switch (entitlement) {
      SupporterEntitlement.included => 'Included',
      SupporterEntitlement.unlocked
          when distribution == SupportDistribution.githubRelease =>
        'GitHub Sponsor',
      SupporterEntitlement.unlocked => 'Supporter',
      SupporterEntitlement.locked
          when distribution == SupportDistribution.githubRelease =>
        'Monthly sponsor',
      SupporterEntitlement.locked => 'Supporter',
    };

    return Row(
      children: <Widget>[
        Icon(Icons.color_lens_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Custom color palette',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: Text(
            badge,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _LockedContent extends StatelessWidget {
  const _LockedContent({required this.distribution});

  final SupportDistribution distribution;

  @override
  Widget build(BuildContext context) {
    if (distribution == SupportDistribution.githubRelease) {
      return const _GitHubSponsorLockedContent();
    }
    return const _GenericLockedContent();
  }
}

class _GitHubSponsorLockedContent extends ConsumerWidget {
  const _GitHubSponsorLockedContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GitHubSponsorStatus? status =
        ref.watch(githubSponsorControllerProvider).valueOrNull;
    final bool checking = status?.access == GitHubSponsorAccess.checking;
    final bool unavailable = status?.access == GitHubSponsorAccess.unavailable;
    final String? message = status?.message;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _PalettePreview(),
        const SizedBox(height: AppSpacing.md),
        const _LockExplanation(
          text: 'The GitHub Release APK unlocks custom colors for active '
              'monthly GitHub Sponsors. Every built-in icon theme and every '
              'core music feature remain free.',
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(
            message,
            key: const Key('github-sponsor-status-message'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('custom-theme-github-sponsors'),
            onPressed: () => context.push(AppRoutes.settingsSupport),
            icon: const Icon(Icons.favorite_outline),
            label: const Text('Sponsor monthly on GitHub'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('custom-theme-connect-github'),
            onPressed: checking || unavailable
                ? null
                : () => _connectGitHub(context, ref),
            icon: checking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(checking ? 'Checking GitHub…' : 'Connect GitHub'),
          ),
        ),
        if (status?.access == GitHubSponsorAccess.inactive ||
            status?.access == GitHubSponsorAccess.error) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('custom-theme-refresh-sponsorship'),
              onPressed: checking
                  ? null
                  : () => ref
                      .read(githubSponsorControllerProvider.notifier)
                      .refresh(),
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _connectGitHub(BuildContext context, WidgetRef ref) async {
    try {
      final GitHubDeviceAuthorization authorization = await ref
          .read(githubSponsorControllerProvider.notifier)
          .beginAuthorization();
      if (!context.mounted) return;

      final bool? unlocked = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => GitHubSponsorUnlockDialog(
          authorization: authorization,
        ),
      );
      if (unlocked == true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('GitHub Sponsor verified. Custom colors unlocked.'),
          ),
        );
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

class _VerifiedGitHubSponsorRow extends ConsumerWidget {
  const _VerifiedGitHubSponsorRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GitHubSponsorStatus? status =
        ref.watch(githubSponsorControllerProvider).valueOrNull;
    return ListTile(
      key: const Key('github-sponsor-verified'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.verified_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('GitHub Sponsor verified'),
      subtitle: Text(
        status?.login == null
            ? 'Monthly sponsorship is active.'
            : 'Connected as @${status!.login}.',
      ),
      trailing: TextButton(
        onPressed: () =>
            ref.read(githubSponsorControllerProvider.notifier).disconnect(),
        child: const Text('Disconnect'),
      ),
    );
  }
}

class _GenericLockedContent extends StatelessWidget {
  const _GenericLockedContent();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _PalettePreview(),
        const SizedBox(height: AppSpacing.md),
        const _LockExplanation(
          text: 'Custom palettes are an optional visual supporter reward. '
              'Every built-in icon theme and every core music feature remain '
              'free.',
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('custom-theme-support-options'),
            onPressed: () => context.push(AppRoutes.settingsSupport),
            icon: const Icon(Icons.favorite_outline),
            label: const Text('View supporter options'),
          ),
        ),
      ],
    );
  }
}

class _LockExplanation extends StatelessWidget {
  const _LockExplanation({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          Icons.lock_outline,
          size: 20,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _PalettePreview extends StatelessWidget {
  const _PalettePreview();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: _choices
          .take(6)
          .map(
            (_ColorChoice choice) => Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: choice.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _ColorSelector extends StatelessWidget {
  const _ColorSelector({
    required this.label,
    required this.roleKey,
    required this.selectedValue,
    required this.onSelected,
  });

  final String label;
  final String roleKey;
  final int selectedValue;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final _ColorChoice choice in _choices)
              _ColorSwatch(
                key: Key('custom-theme-$roleKey-${choice.id}'),
                choice: choice,
                selected: selectedValue == choice.value,
                onTap: () => onSelected(choice.value),
              ),
          ],
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    super.key,
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final _ColorChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: choice.label,
      child: Tooltip(
        message: choice.label,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: choice.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.outline,
                width: selected ? 3 : 1,
              ),
              boxShadow: selected
                  ? <BoxShadow>[
                      BoxShadow(
                        color: choice.color.withValues(alpha: 0.35),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 20,
                    color: ThemeData.estimateBrightnessForColor(choice.color) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _ColorChoice {
  const _ColorChoice(this.id, this.label, this.value);

  final String id;
  final String label;
  final int value;

  Color get color => Color(value);
}

const List<_ColorChoice> _choices = <_ColorChoice>[
  _ColorChoice('violet', 'Violet', 0xFF7C5CFF),
  _ColorChoice('orange', 'Orange', 0xFFFF9F43),
  _ColorChoice('cyan', 'Cyan', 0xFF34C5FF),
  _ColorChoice('blue', 'Blue', 0xFF4D7CFE),
  _ColorChoice('teal', 'Teal', 0xFF22C7A9),
  _ColorChoice('green', 'Green', 0xFF54C46F),
  _ColorChoice('gold', 'Gold', 0xFFF5C518),
  _ColorChoice('pink', 'Pink', 0xFFFF5DA2),
  _ColorChoice('red', 'Red', 0xFFE85D68),
  _ColorChoice('white', 'White', 0xFFFFFFFF),
];
