import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/repositories/download_preferences.dart';
import '../../downloads/download_providers.dart';

/// The smart pre-cache card on the Settings screen.
///
/// Exposes the two pre-cache choices — on/off and how many upcoming tracks to
/// warm — and explains the distinction the feature lives or dies on: smart
/// pre-cache is **automatic and evictable** (it may be removed automatically to
/// stay under the cache limit), whereas **Keep offline** (a manual download) is
/// **protected** and never removed automatically. The widget never caches or
/// evicts anything itself — it only writes the user's choices back through the
/// preference controllers; the `SmartPrecacheService` and cache policy do the
/// rest, honouring the cache limit and the "Allow mobile data" setting.
class PrecacheSettingsSection extends ConsumerWidget {
  const PrecacheSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    final AsyncValue<bool> enabled = ref.watch(smartPrecacheEnabledProvider);
    final bool isOn = enabled.valueOrNull ?? true;
    final int count =
        ref.watch(precacheCountProvider).valueOrNull ?? kDefaultPrecacheCount;

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
                Icon(Icons.auto_awesome_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Smart pre-cache', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Linthra quietly caches the next few tracks in your queue so they '
              'play instantly — even offline. Pre-cached tracks are automatic '
              'and may be removed automatically to stay under your cache limit.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'To keep a song for good, use "Keep offline" on a download — '
              'pinned tracks are protected and never removed automatically.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.bolt_outlined),
              title: const Text('Pre-cache upcoming tracks'),
              subtitle: const Text(
                  'Follows your mobile-data setting and cache limit'),
              value: isOn,
              onChanged: enabled.isLoading
                  ? null
                  : (bool value) => ref
                      .read(smartPrecacheEnabledProvider.notifier)
                      .setEnabled(value),
            ),
            const SizedBox(height: AppSpacing.xs),
            _UpcomingCountSelector(
              count: count,
              enabled: isOn,
              onChanged: (int value) =>
                  ref.read(precacheCountProvider.notifier).setCount(value),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "how many upcoming tracks" picker: a compact segmented control over
/// [kPrecacheCountOptions]. Greyed out (and inert) while smart pre-cache is off,
/// so it reads as "this tunes the feature above".
class _UpcomingCountSelector extends StatelessWidget {
  const _UpcomingCountSelector({
    required this.count,
    required this.enabled,
    required this.onChanged,
  });

  final int count;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final int selected = sanitizePrecacheCount(count);

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Upcoming tracks to cache',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: <ButtonSegment<int>>[
                for (final int option in kPrecacheCountOptions)
                  ButtonSegment<int>(value: option, label: Text('$option')),
              ],
              selected: <int>{selected},
              onSelectionChanged: enabled
                  ? (Set<int> selection) => onChanged(selection.first)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
