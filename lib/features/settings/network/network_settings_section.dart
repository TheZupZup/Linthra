import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../downloads/download_providers.dart';

/// The "Wi-Fi & mobile data" card on the Settings screen.
///
/// Hosts the single mobile-data choice that the whole download/cache stack
/// keys off: with it off (the safe default) downloads and smart pre-cache run
/// only on Wi-Fi; with it on they may also use mobile data. The widget never
/// downloads or caches anything itself — it only writes the user's choice back
/// through the preference controller; the repository and smart pre-cache enforce
/// it (and always keep the cache under its size limit).
class NetworkSettingsSection extends StatelessWidget {
  const NetworkSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.network_cell_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Wi-Fi & mobile data', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'By default Linthra downloads and caches only on Wi-Fi. Allow '
              'mobile data to let offline downloads and cache run on mobile '
              'data too. The storage limit always applies.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            const MobileDataDownloadsTile(contentPadding: EdgeInsets.zero),
          ],
        ),
      ),
    );
  }
}

/// The "Allow mobile data" switch, shared by the Settings card and the Downloads
/// screen so both stay in sync through [allowMobileDataControllerProvider].
///
/// Turning it on first asks for confirmation (mobile data can be expensive);
/// turning it off applies immediately. The widget only writes the preference —
/// the download/pre-cache policy lives in the repository.
class MobileDataDownloadsTile extends ConsumerWidget {
  const MobileDataDownloadsTile({super.key, this.contentPadding});

  /// Lets the Downloads screen use the default list padding while the Settings
  /// card sits flush inside its own padding.
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<bool> allow = ref.watch(allowMobileDataControllerProvider);
    final bool isOn = allow.valueOrNull ?? false;
    return SwitchListTile(
      contentPadding: contentPadding,
      secondary: const Icon(Icons.signal_cellular_alt_outlined),
      title: const Text('Allow mobile data for downloads'),
      subtitle: const Text(
        'When enabled, Linthra can download/cache music using mobile data. '
        'This may use a lot of data.',
      ),
      value: isOn,
      onChanged:
          allow.isLoading ? null : (value) => _toggle(context, ref, value),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool value) async {
    // Turning the switch off is always safe and immediate.
    if (!value) {
      await ref
          .read(allowMobileDataControllerProvider.notifier)
          .setAllowMobileData(false);
      return;
    }
    // Turning it on opts into metered data, so confirm first.
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => const _MobileDataConfirmDialog(),
        ) ??
        false;
    if (!confirmed) return;
    await ref
        .read(allowMobileDataControllerProvider.notifier)
        .setAllowMobileData(true);
  }
}

/// Confirms the opt-in to downloading over mobile data.
class _MobileDataConfirmDialog extends StatelessWidget {
  const _MobileDataConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Use mobile data for downloads?'),
      content: const Text(
        'Caching music over mobile data may use a lot of data depending on '
        'your library and cache settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Allow mobile data'),
        ),
      ],
    );
  }
}
