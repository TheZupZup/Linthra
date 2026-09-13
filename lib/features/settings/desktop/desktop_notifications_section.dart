import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../data/repositories/desktop_notifier_provider.dart';
import 'track_change_notifications_controller.dart';

/// The "Desktop notifications" card on the Music & playback settings page.
///
/// Only shown where Linthra can actually show one: Linux, over D-Bus. On
/// Android the media notification belongs to the media session and the system
/// draws it, so the seam reports itself unsupported and this widget renders
/// nothing rather than offering a switch that would do nothing.
///
/// Off by default, and the card says what turning it on does and what it will
/// never do: a desktop shell already shows a now-playing card from Linthra's
/// media session, so this is an addition rather than the only way to see what
/// is playing.
class DesktopNotificationsSettingsSection extends ConsumerWidget {
  const DesktopNotificationsSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(desktopNotifierProvider).isSupported) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final AsyncValue<bool> enabled =
        ref.watch(trackChangeNotificationsControllerProvider);
    final bool selected = enabled.valueOrNull ?? false;

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
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.notifications_none_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Desktop notifications',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Show a short notification when the song changes, with its '
              'title, artist and cover. Nothing is shown for pausing, '
              'resuming or moving through a track, and skipping quickly only '
              'announces the song you land on.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: selected,
              // Ignore taps until the stored choice has loaded, so a fast tap
              // cannot be overwritten by the value still on its way in from
              // storage.
              onChanged: enabled.isLoading
                  ? null
                  : (bool value) => ref
                      .read(trackChangeNotificationsControllerProvider.notifier)
                      .setEnabled(value),
              title: const Text('Notify me when the track changes'),
              subtitle: const Text(
                'Off by default. Your desktop already shows what is playing '
                'through Linthra’s media controls.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
