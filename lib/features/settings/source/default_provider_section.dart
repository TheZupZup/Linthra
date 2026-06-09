import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/sources/music_provider.dart';
import '../../library/source_preference_controller.dart';

/// One choice in the "Default source" card.
typedef _SourceOption = ({String? id, String title, String? subtitle});

/// The "Default source" card on the Settings screen.
///
/// Lets the user choose which provider to prefer when the same song is available
/// from more than one place (a common self-hosting setup where Jellyfin and
/// Navidrome expose the same library). The choice only changes *which* copy of a
/// duplicated song plays — never whether a song is de-duplicated, and never the
/// audio engine. When the chosen source doesn't have a given song, Linthra falls
/// back to the next available copy.
///
/// "Automatic" (the default) keeps Linthra's behaviour of preferring the server
/// the user most recently signed into.
class DefaultProviderSettingsSection extends ConsumerWidget {
  const DefaultProviderSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String? selected = ref.watch(defaultProviderControllerProvider);

    final List<_SourceOption> options = <_SourceOption>[
      (
        id: null,
        title: 'Automatic',
        subtitle: 'Use the server you most recently signed into.',
      ),
      (
        id: MusicProviders.jellyfin.sourceId,
        title: MusicProviders.jellyfin.displayName,
        subtitle: null,
      ),
      (
        id: MusicProviders.subsonic.sourceId,
        title: MusicProviders.subsonic.displayName,
        subtitle: null,
      ),
      (
        id: MusicProviders.local.sourceId,
        title: MusicProviders.local.displayName,
        subtitle: 'Prefer a copy on this device when one exists.',
      ),
    ];

    void choose(String? sourceId) {
      ref
          .read(defaultProviderControllerProvider.notifier)
          .setDefaultProvider(sourceId);
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
                Icon(Icons.library_music_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Default source', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'When the same song is available from more than one place, play it '
              'from this source. If that source does not have the song, Linthra '
              'uses another available copy.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final _SourceOption option in options)
              RadioListTile<String?>(
                contentPadding: EdgeInsets.zero,
                value: option.id,
                groupValue: selected,
                onChanged: (value) => choose(value),
                title: Text(option.title),
                subtitle:
                    option.subtitle == null ? null : Text(option.subtitle!),
              ),
          ],
        ),
      ),
    );
  }
}
