import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import 'normalize_volume_controller.dart';

/// The "Playback" card on the Settings screen.
///
/// Hosts the "Normalize volume" choice. With it off (the default) audio plays
/// untouched; with it on, playback applies each track's ReplayGain so songs sit
/// at a more even loudness. The widget never touches the audio engine itself —
/// it only writes the user's choice back through the preference controller; the
/// playback layer reads it and applies the (clip-safe, attenuation-only) gain.
class PlaybackSettingsSection extends StatelessWidget {
  const PlaybackSettingsSection({super.key});

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
                Icon(Icons.graphic_eq, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Playback', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Normalize volume evens out loudness between tracks using '
              'ReplayGain tags when a track has them. It only turns loud tracks '
              'down (never up) and never changes the files themselves.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            const NormalizeVolumeTile(contentPadding: EdgeInsets.zero),
          ],
        ),
      ),
    );
  }
}

/// The "Normalize volume" switch. Writes the preference through
/// [normalizeVolumeControllerProvider]; the playback engine reads it and applies
/// the gain. Disabled while the stored value is still loading.
class NormalizeVolumeTile extends ConsumerWidget {
  const NormalizeVolumeTile({super.key, this.contentPadding});

  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<bool> normalize =
        ref.watch(normalizeVolumeControllerProvider);
    final bool isOn = normalize.valueOrNull ?? false;
    return SwitchListTile(
      contentPadding: contentPadding,
      secondary: const Icon(Icons.volume_up_outlined),
      title: const Text('Normalize volume'),
      subtitle: const Text(
        'Play tracks at a more even loudness using their ReplayGain tags. '
        'Off by default.',
      ),
      value: isOn,
      onChanged: normalize.isLoading
          ? null
          : (value) => ref
              .read(normalizeVolumeControllerProvider.notifier)
              .setEnabled(value),
    );
  }
}
