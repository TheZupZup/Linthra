import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/catalog/source_strategy.dart';
import '../../library/playback_source_strategy_controller.dart';

/// The "Playback source strategy" card on the Settings screen.
///
/// Lets the user pick how Linthra orders the copies of a song that exists on more
/// than one source (e.g. prefer a downloaded copy to save data). The choice only
/// reorders candidates before playback; runtime fallback still applies, and the
/// now-playing indicator still shows the copy that actually played. "Prefer
/// default provider" keeps the existing behaviour.
class PlaybackSourceStrategySettingsSection extends ConsumerWidget {
  const PlaybackSourceStrategySettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final PlaybackSourceStrategy selected =
        ref.watch(playbackSourceStrategyProvider);

    void choose(PlaybackSourceStrategy? strategy) {
      if (strategy == null) return;
      ref.read(playbackSourceStrategyProvider.notifier).setStrategy(strategy);
    }

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
                Icon(Icons.tune_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Playback source strategy',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'When the same song is available from more than one place, choose '
              'which copy Linthra plays first. If that copy fails, Linthra still '
              'falls back to another one.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final PlaybackSourceStrategy strategy
                in PlaybackSourceStrategy.values)
              RadioListTile<PlaybackSourceStrategy>(
                contentPadding: EdgeInsets.zero,
                value: strategy,
                groupValue: selected,
                onChanged: choose,
                title: Text(strategy.label),
                subtitle: Text(strategy.description),
              ),
          ],
        ),
      ),
    );
  }
}
